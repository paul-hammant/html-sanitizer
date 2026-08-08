//! The 1:1 symbol table for the HtmlSanitizer C ABI (`core/embed.ae`).
//!
//! This module is the ONLY place in the Rust binding that knows about the C
//! ABI, and it is the canonical cross-binding reference: every symbol the
//! engine exports appears here once, with the exact C signature, in the order
//! `core/embed.ae` declares it. No sanitizer logic lives here or anywhere
//! else in this crate — the engine is `core/htmlsanitizer.ae`.
//!
//! ## Naming
//!
//! `core/embed.ae` names its exports `hs_embed_<name>`; building with
//! `--emit=lib` mangles them to **`aether_hs_embed_<name>`**. That mangled
//! name is what we `dlsym`.
//!
//! ## The two ownership rules
//!
//! 1. **Every `*mut c_char` this ABI returns is caller-owned** and must be
//!    handed back to [`Api::free_string`]. Leaking it is the single most
//!    common bug in a binding. [`Api::take_string`] does the right thing.
//! 2. **Node and attribute pointers handed to a callback are borrowed** —
//!    valid only for the duration of that callback, because the DOM is freed
//!    when `sanitize` returns. Never retain one.
//!
//! ## Callback ABI
//!
//! Each hook receives the opaque `user_data` registered alongside it as its
//! **first** argument; the engine's C trampolines (`core/_embed_support.c`)
//! supply it. Integer arguments are C `int`, not `long`.
//!
//! For the `removing_*` family (tag, attribute, style, comment), a
//! **non-zero return CANCELS the removal** — i.e. keeps the node. `filter_url`
//! returns a malloc'd C string the engine takes ownership of, or the
//! `resolved` pointer unchanged to mean "no rewrite".

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::path::Path;

use libloading::{Library, Symbol};

// ---- allow-list selectors (ABI constants — append only, never renumber) ----

/// `allowed_tags`
pub const TAGS: c_int = 0;
/// `allowed_attributes`
pub const ATTRIBUTES: c_int = 1;
/// `allowed_css_properties`
pub const CSS_PROPERTIES: c_int = 2;
/// `allowed_schemes`
pub const SCHEMES: c_int = 3;
/// `allowed_classes`
pub const CLASSES: c_int = 4;
/// `uri_attributes`
pub const URI_ATTRIBUTES: c_int = 5;

// ---- removal reasons, as passed to the callbacks ----

pub const REASON_NOT_ALLOWED_TAG: c_int = 0;
pub const REASON_NOT_ALLOWED_ATTRIBUTE: c_int = 1;
pub const REASON_NOT_ALLOWED_STYLE: c_int = 2;
pub const REASON_NOT_ALLOWED_URL_VALUE: c_int = 3;
pub const REASON_NOT_ALLOWED_VALUE: c_int = 4;
pub const REASON_NOT_ALLOWED_CSS_CLASS: c_int = 5;
pub const REASON_CLASS_ATTRIBUTE_EMPTY: c_int = 6;
pub const REASON_STYLE_ATTRIBUTE_EMPTY: c_int = 7;

// ---- node kinds ----

pub const NODE_DOCUMENT: c_int = 1;
pub const NODE_ELEMENT: c_int = 2;
pub const NODE_TEXT: c_int = 3;
pub const NODE_COMMENT: c_int = 4;

// ---- callback function types ----
//
// Note each takes `user_data` first, and every integer is `c_int`.

/// `int f(void* ud, void* node, int reason)` — non-zero cancels the removal.
pub type CbRemovingTag = unsafe extern "C" fn(*mut c_void, *mut c_void, c_int) -> c_int;

/// `int f(void* ud, void* elem, void* attr, int reason)` — non-zero cancels.
pub type CbRemovingAttribute =
    unsafe extern "C" fn(*mut c_void, *mut c_void, *mut c_void, c_int) -> c_int;

/// `int f(void* ud, void* elem, const char* name, const char* value, int reason)`
/// — four arguments plus `ud`, unlike the tag/attribute hooks. Non-zero cancels.
pub type CbRemovingStyle = unsafe extern "C" fn(
    *mut c_void,
    *mut c_void,
    *const c_char,
    *const c_char,
    c_int,
) -> c_int;

/// `int f(void* ud, void* node)` — non-zero cancels the removal.
pub type CbRemovingComment = unsafe extern "C" fn(*mut c_void, *mut c_void) -> c_int;

/// `void f(void* ud, void* node)` — used for both post-process hooks.
pub type CbPostProcess = unsafe extern "C" fn(*mut c_void, *mut c_void);

/// `char* f(void* ud, void* elem, const char* raw, const char* resolved)`
///
/// Returns a malloc'd C string the engine takes ownership of, or `resolved`
/// unchanged for "no rewrite".
pub type CbFilterUrl = unsafe extern "C" fn(
    *mut c_void,
    *mut c_void,
    *const c_char,
    *const c_char,
) -> *mut c_char;

/// The platform's shared-library file name for the engine.
pub const LIB_NAME: &str = if cfg!(target_os = "macos") {
    "libhtmlsanitizer.dylib"
} else if cfg!(target_os = "windows") {
    "htmlsanitizer.dll"
} else {
    "libhtmlsanitizer.so"
};

/// Errors from loading or calling the engine.
#[derive(Debug)]
pub enum Error {
    /// The shared library could not be found or opened.
    Load(String),
    /// The library opened but an expected symbol was missing.
    Symbol(String),
    /// The engine refused to allocate a sanitizer.
    Alloc,
    /// The sanitizer handle has already been closed.
    Closed,
    /// A Rust string contained an interior NUL and cannot cross the ABI.
    NulByte,
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Load(m) => write!(
                f,
                "could not load the HtmlSanitizer engine ({LIB_NAME}). Set \
                 HTMLSANITIZER_LIB to its absolute path. Last error: {m}"
            ),
            Error::Symbol(s) => write!(f, "missing symbol {s} (engine too old?)"),
            Error::Alloc => write!(f, "failed to create the native sanitizer"),
            Error::Closed => write!(f, "sanitizer is closed"),
            Error::NulByte => write!(f, "string contains an interior NUL byte"),
        }
    }
}

impl std::error::Error for Error {}

/// Every exported symbol, resolved once at load time.
///
/// Field order mirrors `core/embed.ae` so the two can be diffed by eye.
/// `_lib` is last and must stay last: the `Symbol` values borrow from it, so
/// it has to outlive them (Rust drops fields in declaration order).
pub struct Api {
    // ---- lifecycle ----
    pub new: unsafe extern "C" fn() -> *mut c_void,
    pub free: unsafe extern "C" fn(*mut c_void),
    pub free_string: unsafe extern "C" fn(*mut c_char),

    // ---- the main entry points ----
    pub sanitize: unsafe extern "C" fn(*mut c_void, *const c_char, *const c_char) -> *mut c_char,
    pub sanitize_document:
        unsafe extern "C" fn(*mut c_void, *const c_char, *const c_char) -> *mut c_char,

    // ---- boolean flags ----
    pub set_keep_child_nodes: unsafe extern "C" fn(*mut c_void, c_int),
    pub get_keep_child_nodes: unsafe extern "C" fn(*mut c_void) -> c_int,
    pub set_allow_data_attributes: unsafe extern "C" fn(*mut c_void, c_int),
    pub get_allow_data_attributes: unsafe extern "C" fn(*mut c_void) -> c_int,

    // ---- allow-list mutation (the `which` selector is an ABI constant) ----
    pub allow: unsafe extern "C" fn(*mut c_void, c_int, *const c_char) -> c_int,
    pub disallow: unsafe extern "C" fn(*mut c_void, c_int, *const c_char) -> c_int,
    pub is_allowed: unsafe extern "C" fn(*mut c_void, c_int, *const c_char) -> c_int,
    pub clear: unsafe extern "C" fn(*mut c_void, c_int) -> c_int,
    pub count: unsafe extern "C" fn(*mut c_void, c_int) -> c_int,
    pub item_at: unsafe extern "C" fn(*mut c_void, c_int, c_int) -> *mut c_char,

    // ---- callbacks (fn pointer + opaque user_data; null fn clears) ----
    pub on_removing_tag: unsafe extern "C" fn(*mut c_void, *mut c_void, *mut c_void),
    pub on_removing_attribute: unsafe extern "C" fn(*mut c_void, *mut c_void, *mut c_void),
    pub on_removing_style: unsafe extern "C" fn(*mut c_void, *mut c_void, *mut c_void),
    pub on_removing_comment: unsafe extern "C" fn(*mut c_void, *mut c_void, *mut c_void),
    pub on_post_process_node: unsafe extern "C" fn(*mut c_void, *mut c_void, *mut c_void),
    pub on_post_process_dom: unsafe extern "C" fn(*mut c_void, *mut c_void, *mut c_void),
    pub on_filter_url: unsafe extern "C" fn(*mut c_void, *mut c_void, *mut c_void),

    // ---- DOM accessors (borrowed pointers, valid only inside a callback) ----
    pub node_kind: unsafe extern "C" fn(*mut c_void) -> c_int,
    pub node_name: unsafe extern "C" fn(*mut c_void) -> *mut c_char,
    pub node_value: unsafe extern "C" fn(*mut c_void) -> *mut c_char,
    pub node_child_count: unsafe extern "C" fn(*mut c_void) -> c_int,
    pub node_child_at: unsafe extern "C" fn(*mut c_void, c_int) -> *mut c_void,
    pub node_parent: unsafe extern "C" fn(*mut c_void) -> *mut c_void,
    pub node_attr_count: unsafe extern "C" fn(*mut c_void) -> c_int,
    pub node_attr_at: unsafe extern "C" fn(*mut c_void, c_int) -> *mut c_void,
    pub attr_name: unsafe extern "C" fn(*mut c_void) -> *mut c_char,
    pub attr_value: unsafe extern "C" fn(*mut c_void) -> *mut c_char,
    pub attr_set_value: unsafe extern "C" fn(*mut c_void, *const c_char),

    // ---- version / introspection ----
    pub abi_version: unsafe extern "C" fn() -> c_int,

    /// Keeps the `dlopen` handle alive. MUST be the last field — every fn
    /// pointer above points into this library's mapping.
    _lib: Library,
}

/// Resolve one symbol out of the library, transmuting it to the fn-pointer
/// type the field expects.
macro_rules! sym {
    ($lib:expr, $name:literal) => {{
        let s: Symbol<_> = unsafe { $lib.get(concat!($name, "\0").as_bytes()) }
            .map_err(|_| Error::Symbol($name.to_string()))?;
        // Deref copies the fn pointer out of the Symbol's borrow of `lib`;
        // the pointer stays valid because `Api` keeps the Library alive.
        *s
    }};
}

impl Api {
    /// Load the engine and resolve every symbol.
    ///
    /// Resolution order, matching every other binding in the monorepo:
    ///   1. `explicit`, when given
    ///   2. `$HTMLSANITIZER_LIB`
    ///   3. `native/` next to the crate
    ///   4. the OS loader's own search path
    pub fn load(explicit: Option<&Path>) -> Result<Api, Error> {
        let mut candidates: Vec<String> = Vec::new();
        if let Some(p) = explicit {
            candidates.push(p.display().to_string());
        } else {
            if let Ok(env) = std::env::var("HTMLSANITIZER_LIB") {
                if !env.is_empty() {
                    candidates.push(env);
                }
            }
            candidates.push(
                Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("native")
                    .join(LIB_NAME)
                    .display()
                    .to_string(),
            );
            candidates.push(LIB_NAME.to_string());
        }

        let mut last = String::from("no candidates");
        for cand in &candidates {
            match unsafe { Library::new(cand) } {
                Ok(lib) => return Api::bind(lib),
                Err(e) => last = e.to_string(),
            }
        }
        Err(Error::Load(last))
    }

    fn bind(lib: Library) -> Result<Api, Error> {
        Ok(Api {
            new: sym!(lib, "aether_hs_embed_new"),
            free: sym!(lib, "aether_hs_embed_free"),
            free_string: sym!(lib, "aether_hs_embed_free_string"),

            sanitize: sym!(lib, "aether_hs_embed_sanitize"),
            sanitize_document: sym!(lib, "aether_hs_embed_sanitize_document"),

            set_keep_child_nodes: sym!(lib, "aether_hs_embed_set_keep_child_nodes"),
            get_keep_child_nodes: sym!(lib, "aether_hs_embed_get_keep_child_nodes"),
            set_allow_data_attributes: sym!(lib, "aether_hs_embed_set_allow_data_attributes"),
            get_allow_data_attributes: sym!(lib, "aether_hs_embed_get_allow_data_attributes"),

            allow: sym!(lib, "aether_hs_embed_allow"),
            disallow: sym!(lib, "aether_hs_embed_disallow"),
            is_allowed: sym!(lib, "aether_hs_embed_is_allowed"),
            clear: sym!(lib, "aether_hs_embed_clear"),
            count: sym!(lib, "aether_hs_embed_count"),
            item_at: sym!(lib, "aether_hs_embed_item_at"),

            on_removing_tag: sym!(lib, "aether_hs_embed_on_removing_tag"),
            on_removing_attribute: sym!(lib, "aether_hs_embed_on_removing_attribute"),
            on_removing_style: sym!(lib, "aether_hs_embed_on_removing_style"),
            on_removing_comment: sym!(lib, "aether_hs_embed_on_removing_comment"),
            on_post_process_node: sym!(lib, "aether_hs_embed_on_post_process_node"),
            on_post_process_dom: sym!(lib, "aether_hs_embed_on_post_process_dom"),
            on_filter_url: sym!(lib, "aether_hs_embed_on_filter_url"),

            node_kind: sym!(lib, "aether_hs_embed_node_kind"),
            node_name: sym!(lib, "aether_hs_embed_node_name"),
            node_value: sym!(lib, "aether_hs_embed_node_value"),
            node_child_count: sym!(lib, "aether_hs_embed_node_child_count"),
            node_child_at: sym!(lib, "aether_hs_embed_node_child_at"),
            node_parent: sym!(lib, "aether_hs_embed_node_parent"),
            node_attr_count: sym!(lib, "aether_hs_embed_node_attr_count"),
            node_attr_at: sym!(lib, "aether_hs_embed_node_attr_at"),
            attr_name: sym!(lib, "aether_hs_embed_attr_name"),
            attr_value: sym!(lib, "aether_hs_embed_attr_value"),
            attr_set_value: sym!(lib, "aether_hs_embed_attr_set_value"),

            abi_version: sym!(lib, "aether_hs_embed_abi_version"),

            _lib: lib,
        })
    }

    /// Copy an ABI-returned string out and free it through the ABI.
    ///
    /// # Safety
    /// `ptr` must be a string this ABI returned, and must not be used again.
    pub unsafe fn take_string(&self, ptr: *mut c_char) -> String {
        if ptr.is_null() {
            return String::new();
        }
        let out = unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned();
        unsafe { (self.free_string)(ptr) };
        out
    }
}

/// Read a borrowed `const char *` a callback was handed. NOT owned by us.
///
/// # Safety
/// `ptr` must be null or a valid NUL-terminated string that outlives the call.
pub unsafe fn read_string(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned()
}

/// Convert a Rust string for the ABI. Interior NULs are an error, not a
/// silent truncation.
pub fn to_c(s: &str) -> Result<CString, Error> {
    CString::new(s).map_err(|_| Error::NulByte)
}

/// `strdup` for the one hook that must hand the engine a malloc'd string it
/// will then own (`on_filter_url`).
///
/// Allocated with libc `malloc` because the engine's C side frees it with
/// `free` — a Rust-allocated buffer would be freed by the wrong allocator.
pub fn malloc_cstring(s: &str) -> *mut c_char {
    let bytes = s.as_bytes();
    // One extra byte for the NUL. Truncate at any interior NUL rather than
    // fail: a callback has no way to report an error to the engine.
    let end = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
    let src = &bytes[..end];
    unsafe {
        let p = libc_malloc(src.len() + 1) as *mut u8;
        if p.is_null() {
            return std::ptr::null_mut();
        }
        std::ptr::copy_nonoverlapping(src.as_ptr(), p, src.len());
        *p.add(src.len()) = 0;
        p as *mut c_char
    }
}

// The engine's C support code frees filter_url's result with free(), so the
// matching malloc must come from the same libc. Declaring it directly keeps
// the crate free of a `libc` dependency for one symbol.
unsafe extern "C" {
    #[link_name = "malloc"]
    fn libc_malloc(size: usize) -> *mut c_void;
}
