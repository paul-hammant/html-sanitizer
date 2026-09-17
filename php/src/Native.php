<?php

/**
 * The 1:1 symbol table for the HtmlSanitizer C ABI (core/embed.ae).
 *
 * This file is the ONLY place in the PHP binding that knows about the C ABI.
 * Everything above it (HtmlSanitizer.php) is idiomatic PHP over these symbols.
 * No sanitizer logic lives here or anywhere else in this package — the sanitizer core
 * is core/htmlsanitizer.ae, shared by every language binding.
 *
 * ## Naming
 *
 * core/embed.ae names its exports `hs_embed_<name>`; building with
 * `--emit=lib` mangles them to **`aether_hs_embed_<name>`**. That mangled name
 * is what the cdef below declares.
 *
 * ## The two ownership rules
 *
 *  1. **Every char* this ABI returns is caller-owned** and must be handed back
 *     to `aether_hs_embed_free_string`. Leaking it is the single most common
 *     bug in a binding. {@see Native::takeString()} does the right thing.
 *  2. **Node and attribute pointers handed to a callback are borrowed** —
 *     valid only for the duration of that callback, because the DOM is freed
 *     when `sanitize` returns. Never retain one.
 *
 * ## Callback ABI
 *
 * Each hook receives the opaque `user_data` registered alongside it as its
 * **first** argument. Integer arguments are C `int`, NOT `long` — declaring
 * `long` gives a 4-vs-8-byte mismatch on LP64 and garbage `reason` values.
 *
 * @package HtmlSanitization
 */

declare(strict_types=1);

namespace HtmlSanitization;

use FFI;
use RuntimeException;

/**
 * Loads libhtmlsanitizer and owns the single FFI handle.
 *
 * @psalm-suppress UndefinedClass FFI is only defined when ext-ffi is loaded.
 */
final class Native
{
    // ---- allow-list selectors (ABI constants — append only, never renumber) ----

    public const TAGS = 0;
    public const ATTRIBUTES = 1;
    public const CSS_PROPERTIES = 2;
    public const SCHEMES = 3;
    public const CLASSES = 4;
    public const URI_ATTRIBUTES = 5;

    // ---- removal reasons, as passed to the callbacks ----

    public const REASON_NOT_ALLOWED_TAG = 0;
    public const REASON_NOT_ALLOWED_ATTRIBUTE = 1;
    public const REASON_NOT_ALLOWED_STYLE = 2;
    public const REASON_NOT_ALLOWED_URL_VALUE = 3;
    public const REASON_NOT_ALLOWED_VALUE = 4;
    public const REASON_NOT_ALLOWED_CSS_CLASS = 5;
    public const REASON_CLASS_ATTRIBUTE_EMPTY = 6;
    public const REASON_STYLE_ATTRIBUTE_EMPTY = 7;

    // ---- node kinds ----

    public const NODE_DOCUMENT = 1;
    public const NODE_ELEMENT = 2;
    public const NODE_TEXT = 3;
    public const NODE_COMMENT = 4;

    /**
     * The ABI, in the order core/embed.ae declares it.
     *
     * Comments inside use C block syntax, not line comments: PHP's FFI cdef
     * parser is a small C parser and does not accept the latter.
     *
     * Note the callback typedefs: every one takes `void* user_data` FIRST, and
     * every integer is `int`, never `long`.
     */
    private const CDEF = <<<'C'
        /* ---- the callback shapes ---- */
        /* */
        /* PHP's FFI builds a real C callback ONLY when a PHP Closure is passed */
        /* to a parameter whose declared type is a function pointer. That is */
        /* why the on_* setters below take a typed `fn` rather than `void*`: */
        /* with `void*` PHP has no signature to generate a thunk from and the */
        /* call fails. */
        /* */
        /* Each takes user_data FIRST; every integer is `int`, never `long` */
        /* (the sanitizer core emits its closure calls as int(*)(...), so `long` would */
        /* be a 4-vs-8-byte mismatch on LP64 and garbage `reason` values). */
        typedef int   (*hs_cb_removing_tag)(void* ud, void* node, int reason);
        typedef int   (*hs_cb_removing_attribute)(void* ud, void* elem, void* attr, int reason);
        typedef int   (*hs_cb_removing_style)(void* ud, void* elem, const char* name, const char* value, int reason);
        typedef int   (*hs_cb_removing_comment)(void* ud, void* node);
        typedef void  (*hs_cb_post_process)(void* ud, void* node);
        typedef char* (*hs_cb_filter_url)(void* ud, void* elem, const char* raw, const char* resolved);

        /* ---- lifecycle ---- */
        void*  aether_hs_embed_new(void);
        void   aether_hs_embed_free(void* h);
        void   aether_hs_embed_free_string(char* s);

        /* ---- the main entry point ---- */
        char*  aether_hs_embed_sanitize(void* h, const char* html, const char* base_url);
        char*  aether_hs_embed_sanitize_document(void* h, const char* html, const char* base_url);

        /* ---- boolean flags ---- */
        void   aether_hs_embed_set_keep_child_nodes(void* h, int on);
        int    aether_hs_embed_get_keep_child_nodes(void* h);
        void   aether_hs_embed_set_allow_data_attributes(void* h, int on);
        int    aether_hs_embed_get_allow_data_attributes(void* h);

        /* ---- allow-list mutation ---- */
        int    aether_hs_embed_allow(void* h, int which, const char* item);
        int    aether_hs_embed_disallow(void* h, int which, const char* item);
        int    aether_hs_embed_is_allowed(void* h, int which, const char* item);
        int    aether_hs_embed_clear(void* h, int which);
        int    aether_hs_embed_count(void* h, int which);
        char*  aether_hs_embed_item_at(void* h, int which, int index);

        /* ---- callbacks ---- */
        /* */
        /* The ABI declares `fn` as void*; these declare the concrete function */
        /* pointer so PHP can build the thunk. Same machine-level signature. */
        void   aether_hs_embed_on_removing_tag(void* h, hs_cb_removing_tag fn, void* user_data);
        void   aether_hs_embed_on_removing_attribute(void* h, hs_cb_removing_attribute fn, void* user_data);
        void   aether_hs_embed_on_removing_style(void* h, hs_cb_removing_style fn, void* user_data);
        void   aether_hs_embed_on_removing_comment(void* h, hs_cb_removing_comment fn, void* user_data);
        void   aether_hs_embed_on_post_process_node(void* h, hs_cb_post_process fn, void* user_data);
        void   aether_hs_embed_on_post_process_dom(void* h, hs_cb_post_process fn, void* user_data);
        void   aether_hs_embed_on_filter_url(void* h, hs_cb_filter_url fn, void* user_data);

        /* ---- DOM accessors (for use inside callbacks) ---- */
        int    aether_hs_embed_node_kind(void* n);
        char*  aether_hs_embed_node_name(void* n);
        char*  aether_hs_embed_node_value(void* n);
        int    aether_hs_embed_node_child_count(void* n);
        void*  aether_hs_embed_node_child_at(void* n, int index);
        void*  aether_hs_embed_node_parent(void* n);
        int    aether_hs_embed_node_attr_count(void* n);
        void*  aether_hs_embed_node_attr_at(void* n, int index);
        char*  aether_hs_embed_attr_name(void* a);
        char*  aether_hs_embed_attr_value(void* a);
        void   aether_hs_embed_attr_set_value(void* a, const char* value);

        /* ---- version / introspection ---- */
        int    aether_hs_embed_abi_version(void);

        /* ---- the allocator the sanitizer core itself frees with ---- */
        /* */
        /* on_filter_url must return a buffer the sanitizer core frees. FFI::new's */
        /* memory is owned by PHP and would be freed a second time, so the */
        /* replacement URL has to come from malloc. hs_raw_dup is the sanitizer core's */
        /* own malloc'd strdup (core/_embed_support.c) and is exported by the */
        /* same .so, so it needs no second FFI::cdef against libc — and it is */
        /* by construction the exact counterpart of the sanitizer core's free(). */
        char*  hs_raw_dup(const char* s);
        C;

    private static ?FFI $ffi = null;
    private static ?string $path = null;

    /**
     * Load the sanitizer core, caching it process-wide when no explicit path is given.
     *
     * Resolution order:
     *   1. an explicit $path passed here
     *   2. $HTMLSANITIZER_LIB (what the in-tree .tests.ae leaf sets)
     *   3. native/ next to this package, then ../core/native/
     *   4. the OS loader's own search path
     *
     * @throws RuntimeException when ext-ffi is missing or no candidate loads.
     */
    public static function load(?string $path = null): FFI
    {
        if ($path === null && self::$ffi !== null) {
            return self::$ffi;
        }

        if (!\extension_loaded('ffi')) {
            throw new RuntimeException(
                'htmlsanitizer: ext-ffi is not loaded. Enable it in php.ini '
                . '(extension=ffi) and make sure ffi.enable is "true" for CLI.'
            );
        }

        $tried = [];
        $last = null;
        foreach (self::candidates($path) as $candidate) {
            $tried[] = $candidate;
            try {
                $ffi = FFI::cdef(self::CDEF, $candidate);
            } catch (\Throwable $e) {
                $last = $e;
                continue;
            }
            if ($path === null) {
                self::$ffi = $ffi;
                self::$path = $candidate;
            }
            return $ffi;
        }

        throw new RuntimeException(sprintf(
            "htmlsanitizer: could not load the sanitizer core (%s). Set "
            . "HTMLSANITIZER_LIB to its absolute path, or build it with:\n"
            . "  cd core && ae build --emit=lib embed.ae --extra _embed_support.c "
            . "-o native/%s\nTried: %s\nLast error: %s",
            self::fileName(),
            self::fileName(),
            implode(', ', $tried),
            $last !== null ? $last->getMessage() : '(none)'
        ));
    }

    /** Where the sanitizer core was actually loaded from, once known. */
    public static function path(): ?string
    {
        return self::$path;
    }

    /** The platform's library file name. */
    public static function fileName(): string
    {
        return match (PHP_OS_FAMILY) {
            'Darwin'  => 'libhtmlsanitizer.dylib',
            'Windows' => 'htmlsanitizer.dll',
            default   => 'libhtmlsanitizer.so',
        };
    }

    /**
     * @return list<string>
     */
    private static function candidates(?string $explicit): array
    {
        if ($explicit !== null && $explicit !== '') {
            return [$explicit];
        }

        $out = [];
        $env = \getenv('HTMLSANITIZER_LIB');
        if (\is_string($env) && $env !== '') {
            $out[] = $env;
        }

        $name = self::fileName();
        $here = __DIR__;
        $out[] = $here . '/../native/' . $name;
        $out[] = $here . '/../../core/native/' . $name;
        $out[] = \getcwd() . '/native/' . $name;
        $out[] = \getcwd() . '/../core/native/' . $name;
        $out[] = $name;

        return $out;
    }

    /**
     * Copy an ABI-returned string out and free it through the ABI.
     *
     * Every char* the sanitizer core returns is caller-owned; leaking it is the single
     * easiest mistake to make in any of these bindings. Every string result in
     * this package goes through here.
     *
     * @param FFI\CData|null $ptr
     */
    public static function takeString(FFI $ffi, $ptr): string
    {
        if ($ptr === null || FFI::isNull($ptr)) {
            return '';
        }
        try {
            return FFI::string($ptr);
        } finally {
            $ffi->aether_hs_embed_free_string($ptr);
        }
    }

    /**
     * Read a BORROWED const char* (a callback argument) without freeing it —
     * the sanitizer core owns those.
     *
     * PHP's FFI may hand a `const char*` callback argument to the closure
     * either as an `FFI\CData` pointer or, since the ae >= 0.677 callback ABI,
     * already decoded to a native PHP string. Accept both: a string is returned
     * as-is (`FFI::isNull` would fatal on it — the v0.315/ae-0.681 regression),
     * a CData pointer is read through `FFI::string`.
     *
     * @param FFI\CData|string|null $ptr
     */
    public static function borrowString($ptr): string
    {
        if ($ptr === null) {
            return '';
        }
        if (is_string($ptr)) {
            return $ptr;
        }
        if (FFI::isNull($ptr)) {
            return '';
        }
        return FFI::string($ptr);
    }
}
