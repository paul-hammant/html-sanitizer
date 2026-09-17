//! Cleans HTML of constructs that can lead to XSS.
//!
//! ```no_run
//! use htmlsanitizer::HtmlSanitizer;
//!
//! let mut s = HtmlSanitizer::new().unwrap();
//! assert_eq!(s.sanitize(r#"<div onclick="alert(1)">Hello</div>"#), "<div>Hello</div>");
//! ```
//!
//! This crate carries **no sanitizer logic**. The sanitizer core — HTML5 tokenizer,
//! DOM, CSS parser, URL resolver, allow-lists — is the pure-Aether
//! `core/htmlsanitizer.ae`, shared by every language binding in this monorepo
//! and reached over the `aether_hs_embed_*` C ABI. Everything here is
//! marshalling; see [`native`] for the 1:1 symbol table.

use std::ffi::{c_char, c_int, c_void};
use std::path::Path;

pub mod native;

pub use native::{
    Error, ATTRIBUTES, CLASSES, CSS_PROPERTIES, NODE_COMMENT, NODE_DOCUMENT, NODE_ELEMENT,
    NODE_TEXT, REASON_CLASS_ATTRIBUTE_EMPTY, REASON_NOT_ALLOWED_ATTRIBUTE,
    REASON_NOT_ALLOWED_CSS_CLASS, REASON_NOT_ALLOWED_STYLE, REASON_NOT_ALLOWED_TAG,
    REASON_NOT_ALLOWED_URL_VALUE, REASON_NOT_ALLOWED_VALUE, REASON_STYLE_ATTRIBUTE_EMPTY, SCHEMES,
    TAGS, URI_ATTRIBUTES,
};

use native::Api;

/// A DOM attribute, borrowed for the duration of a callback.
///
/// The lifetime ties it to the callback's borrow of the sanitizer core: the DOM is
/// freed when `sanitize` returns, so an `Attribute` cannot outlive the hook
/// that received it.
pub struct Attribute<'a> {
    api: &'a Api,
    ptr: *mut c_void,
}

impl<'a> Attribute<'a> {
    fn new(api: &'a Api, ptr: *mut c_void) -> Self {
        Attribute { api, ptr }
    }

    pub fn name(&self) -> String {
        unsafe { self.api.take_string((self.api.attr_name)(self.ptr)) }
    }

    pub fn value(&self) -> String {
        unsafe { self.api.take_string((self.api.attr_value)(self.ptr)) }
    }

    /// Rewrite the attribute's value in place (e.g. to canonicalise a URL
    /// rather than let the attribute be removed).
    pub fn set_value(&self, v: &str) {
        if let Ok(c) = native::to_c(v) {
            unsafe { (self.api.attr_set_value)(self.ptr, c.as_ptr()) };
        }
    }
}

impl std::fmt::Debug for Attribute<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Attribute")
            .field("name", &self.name())
            .field("value", &self.value())
            .finish()
    }
}

/// A DOM node, borrowed for the duration of a callback.
pub struct Node<'a> {
    api: &'a Api,
    ptr: *mut c_void,
}

impl<'a> Node<'a> {
    fn new(api: &'a Api, ptr: *mut c_void) -> Self {
        Node { api, ptr }
    }

    /// [`NODE_DOCUMENT`], [`NODE_ELEMENT`], [`NODE_TEXT`] or [`NODE_COMMENT`].
    pub fn kind(&self) -> i32 {
        unsafe { (self.api.node_kind)(self.ptr) }
    }

    /// Element tag name, lowercased by the parser; empty for non-elements.
    pub fn name(&self) -> String {
        unsafe { self.api.take_string((self.api.node_name)(self.ptr)) }
    }

    /// Text/comment content; empty for elements and documents.
    pub fn value(&self) -> String {
        unsafe { self.api.take_string((self.api.node_value)(self.ptr)) }
    }

    pub fn parent(&self) -> Option<Node<'a>> {
        let p = unsafe { (self.api.node_parent)(self.ptr) };
        if p.is_null() {
            None
        } else {
            Some(Node::new(self.api, p))
        }
    }

    pub fn children(&self) -> Vec<Node<'a>> {
        let n = unsafe { (self.api.node_child_count)(self.ptr) };
        (0..n)
            .map(|i| Node::new(self.api, unsafe { (self.api.node_child_at)(self.ptr, i) }))
            .collect()
    }

    pub fn attributes(&self) -> Vec<Attribute<'a>> {
        let n = unsafe { (self.api.node_attr_count)(self.ptr) };
        (0..n)
            .map(|i| Attribute::new(self.api, unsafe { (self.api.node_attr_at)(self.ptr, i) }))
            .collect()
    }
}

impl std::fmt::Debug for Node<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Node")
            .field("kind", &self.kind())
            .field("name", &self.name())
            .finish()
    }
}

/// The boxed Rust closures behind the seven hooks.
///
/// Each is kept alive in the [`HtmlSanitizer`] for as long as the sanitizer core can
/// call it; the raw pointer we hand the ABI as `user_data` points at one of
/// these boxes. Dropping one while the sanitizer core still holds the pointer would
/// be a use-after-free, so they are only replaced or dropped in
/// `install_*`/`Drop`, never while `sanitize` is running.
#[derive(Default)]
struct Hooks {
    removing_tag: Option<Box<dyn FnMut(&Node, i32) -> bool>>,
    removing_attribute: Option<Box<dyn FnMut(&Node, &Attribute, i32) -> bool>>,
    removing_style: Option<Box<dyn FnMut(&Node, &str, &str, i32) -> bool>>,
    removing_comment: Option<Box<dyn FnMut(&Node) -> bool>>,
    post_process_node: Option<Box<dyn FnMut(&Node)>>,
    post_process_dom: Option<Box<dyn FnMut(&Node)>>,
    filter_url: Option<Box<dyn FnMut(&Node, &str, &str) -> String>>,
}

/// What the ABI hands back to a trampoline as `user_data`: the API table (to
/// read the DOM with) and the hook set (to dispatch into).
struct CallbackCtx {
    api: *const Api,
    hooks: *mut Hooks,
}

/// Cleans HTML of constructs that can lead to XSS.
///
/// ```no_run
/// # use htmlsanitizer::HtmlSanitizer;
/// let mut s = HtmlSanitizer::new().unwrap();
/// s.allowed_tags().add("my-widget");
/// let clean = s.sanitize("<my-widget>hi</my-widget>");
/// ```
///
/// The native handle is released on drop.
pub struct HtmlSanitizer {
    api: Box<Api>,
    handle: *mut c_void,
    hooks: Box<Hooks>,
    /// The `user_data` every installed hook was registered with. Boxed so its
    /// address is stable even as the sanitizer moves.
    ctx: Box<CallbackCtx>,
}

impl HtmlSanitizer {
    /// Load the sanitizer core and create a sanitizer with the secure defaults.
    pub fn new() -> Result<HtmlSanitizer, Error> {
        HtmlSanitizer::with_library(None)
    }

    /// As [`HtmlSanitizer::new`], but loading the sanitizer core from an explicit path.
    pub fn with_library(path: Option<&Path>) -> Result<HtmlSanitizer, Error> {
        let api = Box::new(Api::load(path)?);
        let handle = unsafe { (api.new)() };
        if handle.is_null() {
            return Err(Error::Alloc);
        }
        let mut hooks = Box::new(Hooks::default());
        let ctx = Box::new(CallbackCtx {
            api: &*api as *const Api,
            hooks: &mut *hooks as *mut Hooks,
        });
        Ok(HtmlSanitizer {
            api,
            handle,
            hooks,
            ctx,
        })
    }

    /// The sanitizer core's ABI revision.
    pub fn abi_version(&self) -> i32 {
        unsafe { (self.api.abi_version)() }
    }

    // ---- the main entry points ----

    /// Sanitize an HTML fragment. `base_url` may be empty (no resolution of
    /// relative URLs).
    pub fn sanitize(&self, html: &str) -> String {
        self.sanitize_with_base(html, "")
    }

    pub fn sanitize_with_base(&self, html: &str, base_url: &str) -> String {
        let (h, b) = match (native::to_c(html), native::to_c(base_url)) {
            (Ok(h), Ok(b)) => (h, b),
            _ => return String::new(),
        };
        unsafe {
            self.api
                .take_string((self.api.sanitize)(self.handle, h.as_ptr(), b.as_ptr()))
        }
    }

    /// Sanitize a full HTML document.
    pub fn sanitize_document(&self, html: &str) -> String {
        self.sanitize_document_with_base(html, "")
    }

    pub fn sanitize_document_with_base(&self, html: &str, base_url: &str) -> String {
        let (h, b) = match (native::to_c(html), native::to_c(base_url)) {
            (Ok(h), Ok(b)) => (h, b),
            _ => return String::new(),
        };
        unsafe {
            self.api.take_string((self.api.sanitize_document)(
                self.handle,
                h.as_ptr(),
                b.as_ptr(),
            ))
        }
    }

    // ---- flags ----

    /// Keep the children of a removed element instead of dropping the subtree.
    pub fn keep_child_nodes(&self) -> bool {
        unsafe { (self.api.get_keep_child_nodes)(self.handle) != 0 }
    }

    pub fn set_keep_child_nodes(&mut self, on: bool) -> &mut Self {
        unsafe { (self.api.set_keep_child_nodes)(self.handle, on as c_int) };
        self
    }

    /// Allow `data-*` attributes through without listing each one.
    pub fn allow_data_attributes(&self) -> bool {
        unsafe { (self.api.get_allow_data_attributes)(self.handle) != 0 }
    }

    pub fn set_allow_data_attributes(&mut self, on: bool) -> &mut Self {
        unsafe { (self.api.set_allow_data_attributes)(self.handle, on as c_int) };
        self
    }

    // ---- allow-lists ----

    /// A set-like view over one of the six policy lists.
    pub fn allow_list(&self, which: c_int) -> AllowList<'_> {
        AllowList { owner: self, which }
    }

    pub fn allowed_tags(&self) -> AllowList<'_> {
        self.allow_list(TAGS)
    }
    pub fn allowed_attributes(&self) -> AllowList<'_> {
        self.allow_list(ATTRIBUTES)
    }
    pub fn allowed_css_properties(&self) -> AllowList<'_> {
        self.allow_list(CSS_PROPERTIES)
    }
    pub fn allowed_schemes(&self) -> AllowList<'_> {
        self.allow_list(SCHEMES)
    }
    pub fn allowed_classes(&self) -> AllowList<'_> {
        self.allow_list(CLASSES)
    }
    pub fn uri_attributes(&self) -> AllowList<'_> {
        self.allow_list(URI_ATTRIBUTES)
    }

    // ---- callbacks ----
    //
    // Each `on_*` boxes the handler into `self.hooks` and registers a
    // trampoline with `&*self.ctx` as user_data. The trampolines are plain
    // `extern "C"` fns, so there is exactly one per hook shape regardless of
    // how many closures a program installs.

    /// Returning `true` from `handler` CANCELS the removal (keeps the tag).
    pub fn on_removing_tag<F>(&mut self, handler: F) -> &mut Self
    where
        F: FnMut(&Node, i32) -> bool + 'static,
    {
        self.hooks.removing_tag = Some(Box::new(handler));
        let ud = &*self.ctx as *const CallbackCtx as *mut c_void;
        unsafe {
            (self.api.on_removing_tag)(self.handle, tramp_removing_tag as *mut c_void, ud);
        }
        self
    }

    /// Returning `true` CANCELS the removal (keeps the attribute).
    pub fn on_removing_attribute<F>(&mut self, handler: F) -> &mut Self
    where
        F: FnMut(&Node, &Attribute, i32) -> bool + 'static,
    {
        self.hooks.removing_attribute = Some(Box::new(handler));
        let ud = &*self.ctx as *const CallbackCtx as *mut c_void;
        unsafe {
            (self.api.on_removing_attribute)(
                self.handle,
                tramp_removing_attribute as *mut c_void,
                ud,
            );
        }
        self
    }

    /// The four-argument hook: `(element, property_name, property_value, reason)`.
    /// Returning `true` CANCELS the removal (keeps the property).
    pub fn on_removing_style<F>(&mut self, handler: F) -> &mut Self
    where
        F: FnMut(&Node, &str, &str, i32) -> bool + 'static,
    {
        self.hooks.removing_style = Some(Box::new(handler));
        let ud = &*self.ctx as *const CallbackCtx as *mut c_void;
        unsafe {
            (self.api.on_removing_style)(self.handle, tramp_removing_style as *mut c_void, ud);
        }
        self
    }

    /// Returning `true` CANCELS the removal (keeps the comment).
    pub fn on_removing_comment<F>(&mut self, handler: F) -> &mut Self
    where
        F: FnMut(&Node) -> bool + 'static,
    {
        self.hooks.removing_comment = Some(Box::new(handler));
        let ud = &*self.ctx as *const CallbackCtx as *mut c_void;
        unsafe {
            (self.api.on_removing_comment)(self.handle, tramp_removing_comment as *mut c_void, ud);
        }
        self
    }

    pub fn on_post_process_node<F>(&mut self, handler: F) -> &mut Self
    where
        F: FnMut(&Node) + 'static,
    {
        self.hooks.post_process_node = Some(Box::new(handler));
        let ud = &*self.ctx as *const CallbackCtx as *mut c_void;
        unsafe {
            (self.api.on_post_process_node)(self.handle, tramp_post_node as *mut c_void, ud);
        }
        self
    }

    pub fn on_post_process_dom<F>(&mut self, handler: F) -> &mut Self
    where
        F: FnMut(&Node) + 'static,
    {
        self.hooks.post_process_dom = Some(Box::new(handler));
        let ud = &*self.ctx as *const CallbackCtx as *mut c_void;
        unsafe {
            (self.api.on_post_process_dom)(self.handle, tramp_post_dom as *mut c_void, ud);
        }
        self
    }

    /// `handler(node, raw_url, resolved_url) -> String`
    ///
    /// Return the URL to use; an empty string drops the attribute. The result
    /// is copied into a malloc'd buffer the sanitizer core takes ownership of.
    pub fn on_filter_url<F>(&mut self, handler: F) -> &mut Self
    where
        F: FnMut(&Node, &str, &str) -> String + 'static,
    {
        self.hooks.filter_url = Some(Box::new(handler));
        let ud = &*self.ctx as *const CallbackCtx as *mut c_void;
        unsafe {
            (self.api.on_filter_url)(self.handle, tramp_filter_url as *mut c_void, ud);
        }
        self
    }
}

impl Drop for HtmlSanitizer {
    fn drop(&mut self) {
        if !self.handle.is_null() {
            // Frees the sanitizer core's callback boxes too, so no trampoline can be
            // invoked after this point — which is what makes dropping
            // `hooks` immediately afterwards sound.
            unsafe { (self.api.free)(self.handle) };
            self.handle = std::ptr::null_mut();
        }
    }
}

// A sanitizer owns its handle exclusively; the sanitizer core has no global state.
// It is NOT `Sync`, because the hook closures are `FnMut` and the sanitizer core
// calls them re-entrantly during `sanitize`.
unsafe impl Send for HtmlSanitizer {}

/// Set-like view over one of the sanitizer core's six policy lists.
pub struct AllowList<'a> {
    owner: &'a HtmlSanitizer,
    which: c_int,
}

impl AllowList<'_> {
    pub fn add(&self, item: &str) -> &Self {
        if let Ok(c) = native::to_c(item) {
            unsafe { (self.owner.api.allow)(self.owner.handle, self.which, c.as_ptr()) };
        }
        self
    }

    pub fn extend<I: IntoIterator<Item = S>, S: AsRef<str>>(&self, items: I) -> &Self {
        for i in items {
            self.add(i.as_ref());
        }
        self
    }

    /// The "deny" direction — drop an entry that is currently allowed.
    pub fn remove(&self, item: &str) -> &Self {
        if let Ok(c) = native::to_c(item) {
            unsafe { (self.owner.api.disallow)(self.owner.handle, self.which, c.as_ptr()) };
        }
        self
    }

    pub fn contains(&self, item: &str) -> bool {
        match native::to_c(item) {
            Ok(c) => unsafe {
                (self.owner.api.is_allowed)(self.owner.handle, self.which, c.as_ptr()) != 0
            },
            Err(_) => false,
        }
    }

    /// Empty the list — the "start from nothing" move for a strict policy.
    pub fn clear(&self) -> &Self {
        unsafe { (self.owner.api.clear)(self.owner.handle, self.which) };
        self
    }

    pub fn len(&self) -> usize {
        unsafe { (self.owner.api.count)(self.owner.handle, self.which).max(0) as usize }
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Snapshot the list. Iteration order is unspecified but each entry
    /// appears exactly once.
    pub fn to_vec(&self) -> Vec<String> {
        let n = unsafe { (self.owner.api.count)(self.owner.handle, self.which) };
        (0..n)
            .map(|i| unsafe {
                self.owner
                    .api
                    .take_string((self.owner.api.item_at)(self.owner.handle, self.which, i))
            })
            .collect()
    }
}

impl std::fmt::Debug for AllowList<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mut v = self.to_vec();
        v.sort();
        f.debug_set().entries(v.iter()).finish()
    }
}

// ---- trampolines ----
//
// One plain `extern "C"` function per hook shape. Each recovers the
// `CallbackCtx` from `user_data`, rebuilds the borrowed Node/Attribute views,
// and dispatches into the boxed closure. `ud` is always the pointer we
// registered, so the dereference is sound for as long as the sanitizer lives
// — and the sanitizer core cannot call a hook after `free`, which is what `Drop`
// relies on.

/// Recover `(api, hooks)` from the `user_data` the ABI hands back.
///
/// # Safety
/// `ud` must be the `CallbackCtx` pointer registered with the hook.
unsafe fn ctx<'a>(ud: *mut c_void) -> Option<(&'a Api, &'a mut Hooks)> {
    if ud.is_null() {
        return None;
    }
    let c = unsafe { &*(ud as *const CallbackCtx) };
    if c.api.is_null() || c.hooks.is_null() {
        return None;
    }
    Some((unsafe { &*c.api }, unsafe { &mut *c.hooks }))
}

unsafe extern "C" fn tramp_removing_tag(
    ud: *mut c_void,
    node: *mut c_void,
    reason: c_int,
) -> c_int {
    let Some((api, hooks)) = (unsafe { ctx(ud) }) else {
        return 0;
    };
    let Some(f) = hooks.removing_tag.as_mut() else {
        return 0;
    };
    f(&Node::new(api, node), reason) as c_int
}

unsafe extern "C" fn tramp_removing_attribute(
    ud: *mut c_void,
    elem: *mut c_void,
    attr: *mut c_void,
    reason: c_int,
) -> c_int {
    let Some((api, hooks)) = (unsafe { ctx(ud) }) else {
        return 0;
    };
    let Some(f) = hooks.removing_attribute.as_mut() else {
        return 0;
    };
    f(&Node::new(api, elem), &Attribute::new(api, attr), reason) as c_int
}

unsafe extern "C" fn tramp_removing_style(
    ud: *mut c_void,
    elem: *mut c_void,
    name: *const c_char,
    value: *const c_char,
    reason: c_int,
) -> c_int {
    let Some((api, hooks)) = (unsafe { ctx(ud) }) else {
        return 0;
    };
    let Some(f) = hooks.removing_style.as_mut() else {
        return 0;
    };
    let (n, v) = unsafe { (native::read_string(name), native::read_string(value)) };
    f(&Node::new(api, elem), &n, &v, reason) as c_int
}

unsafe extern "C" fn tramp_removing_comment(ud: *mut c_void, node: *mut c_void) -> c_int {
    let Some((api, hooks)) = (unsafe { ctx(ud) }) else {
        return 0;
    };
    let Some(f) = hooks.removing_comment.as_mut() else {
        return 0;
    };
    f(&Node::new(api, node)) as c_int
}

unsafe extern "C" fn tramp_post_node(ud: *mut c_void, node: *mut c_void) {
    let Some((api, hooks)) = (unsafe { ctx(ud) }) else {
        return;
    };
    if let Some(f) = hooks.post_process_node.as_mut() {
        f(&Node::new(api, node));
    }
}

unsafe extern "C" fn tramp_post_dom(ud: *mut c_void, doc: *mut c_void) {
    let Some((api, hooks)) = (unsafe { ctx(ud) }) else {
        return;
    };
    if let Some(f) = hooks.post_process_dom.as_mut() {
        f(&Node::new(api, doc));
    }
}

unsafe extern "C" fn tramp_filter_url(
    ud: *mut c_void,
    elem: *mut c_void,
    raw: *const c_char,
    resolved: *const c_char,
) -> *mut c_char {
    let Some((api, hooks)) = (unsafe { ctx(ud) }) else {
        // "No rewrite" — hand the resolved pointer straight back; the C
        // trampoline recognises it and neither copies nor frees it.
        return resolved as *mut c_char;
    };
    let Some(f) = hooks.filter_url.as_mut() else {
        return resolved as *mut c_char;
    };
    let (r, s) = unsafe { (native::read_string(raw), native::read_string(resolved)) };
    let out = f(&Node::new(api, elem), &r, &s);
    // The sanitizer core takes ownership of this buffer and frees it with libc free.
    native::malloc_cstring(&out)
}
