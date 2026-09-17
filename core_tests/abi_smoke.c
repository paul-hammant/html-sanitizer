/* core_tests/abi_smoke.c — a pure-C consumer of the HtmlSanitizer C ABI.
 *
 * This is the FIRST binding, in the sense that matters: it uses nothing but
 * dlopen + the exported symbols, exactly as every language binding does. If
 * this passes, the ABI is sound and each binding is just marshalling.
 *
 * Deliberately covers the parts a naive smoke test would skip:
 *   - the caller-owned string contract (every char* freed through the ABI)
 *   - allow-list mutation AND enumeration (the MapKeys read path)
 *   - all six callback shapes, including the 4-arg style hook and the
 *     string-returning filter_url hook
 *   - the user_data round-trip (the pointer a binding uses to find itself)
 *
 * Built + run by core_tests/.abi.ae.
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;

static void check_str(const char* what, const char* got, const char* want) {
    if (!got || strcmp(got, want) != 0) {
        printf("  FAIL %s:\n    got  '%s'\n    want '%s'\n", what, got ? got : "(null)", want);
        failures++;
    } else {
        printf("  PASS %s\n", what);
    }
}

static void check_int(const char* what, long got, long want) {
    if (got != want) {
        printf("  FAIL %s: got %ld, want %ld\n", what, got, want);
        failures++;
    } else {
        printf("  PASS %s\n", what);
    }
}

/* ---- the ABI ---- */
static void* (*hs_new)(void);
static void  (*hs_free)(void*);
static void  (*hs_free_string)(char*);
static char* (*hs_sanitize)(void*, const char*, const char*);
static char* (*hs_sanitize_document)(void*, const char*, const char*);
static void  (*hs_set_keep_child_nodes)(void*, int);
static void  (*hs_set_allow_data_attributes)(void*, int);
static int   (*hs_allow)(void*, int, const char*);
static int   (*hs_disallow)(void*, int, const char*);
static int   (*hs_is_allowed)(void*, int, const char*);
static int   (*hs_clear)(void*, int);
static int   (*hs_count)(void*, int);
static char* (*hs_item_at)(void*, int, int);
static int   (*hs_abi_version)(void);
static void  (*hs_on_removing_tag)(void*, void*, void*);
static void  (*hs_on_removing_attribute)(void*, void*, void*);
static void  (*hs_on_removing_comment)(void*, void*, void*);
static void  (*hs_on_removing_style)(void*, void*, void*);
static void  (*hs_on_filter_url)(void*, void*, void*);
static void  (*hs_on_post_process_node)(void*, void*, void*);
static int   (*hs_node_kind)(void*);
static char* (*hs_node_name)(void*);
static char* (*hs_attr_name)(void*);
static char* (*hs_attr_value)(void*);

#define SYM(var, name) \
    do { \
        *(void**)(&var) = dlsym(lib, name); \
        if (!var) { printf("  FAIL missing symbol %s\n", name); return 1; } \
    } while (0)

/* ---- callbacks under test ---- */

/* user_data round-trip: each callback asserts it got its own marker back. */
static const char* MARKER = "user-data-marker";

static int keep_disallowed_tag(void* ud, void* node, int reason) {
    (void)reason;
    if (ud != (void*)MARKER) { printf("  FAIL removing_tag user_data mismatch\n"); failures++; }
    char* name = hs_node_name(node);
    long keep = (name && strcmp(name, "keep-me") == 0) ? 1 : 0;
    hs_free_string(name);
    return keep;   /* non-zero cancels the removal */
}

static int attr_hook_calls = 0;
static int keep_onclick(void* ud, void* elem, void* attr, int reason) {
    (void)elem; (void)reason;
    if (ud != (void*)MARKER) { printf("  FAIL removing_attribute user_data mismatch\n"); failures++; }
    attr_hook_calls++;
    char* n = hs_attr_name(attr);
    char* v = hs_attr_value(attr);
    /* prove both accessors read the real attribute */
    if (!n || !v || strcmp(n, "onclick") != 0) {
        printf("  FAIL removing_attribute saw name='%s'\n", n ? n : "(null)");
        failures++;
    }
    hs_free_string(n);
    hs_free_string(v);
    return 0;   /* 0 = proceed with removal */
}

static int keep_comments(void* ud, void* node) {
    (void)node;
    if (ud != (void*)MARKER) { printf("  FAIL removing_comment user_data mismatch\n"); failures++; }
    return 1;   /* cancel removal — keep the comment */
}

static int style_hook_calls = 0;
static int style_hook(void* ud, void* elem, const char* name, const char* value, int reason) {
    (void)elem; (void)reason; (void)value;
    if (ud != (void*)MARKER) { printf("  FAIL removing_style user_data mismatch\n"); failures++; }
    style_hook_calls++;
    /* keep the otherwise-disallowed property so we can see the effect */
    return (name && strcmp(name, "-custom-thing") == 0) ? 1 : 0;
}

/* filter_url returns a malloc'd C string the sanitizer core takes ownership of, or
 * the `resolved` pointer unchanged to mean "no rewrite". */
static char* rewrite_url(void* ud, void* elem, const char* raw, const char* resolved) {
    (void)elem; (void)raw;
    if (ud != (void*)MARKER) { printf("  FAIL filter_url user_data mismatch\n"); failures++; }
    if (resolved && strcmp(resolved, "https://example.com/logo.png") == 0) {
        return strdup("https://cdn.example.net/logo.png");
    }
    return (char*)resolved;
}

static int post_node_calls = 0;
static void count_nodes(void* ud, void* node) {
    (void)ud; (void)node;
    post_node_calls++;
}

int main(int argc, char** argv) {
    const char* path = (argc > 1) ? argv[1] : "../core/native/libhtmlsanitizer.so";
    void* lib = dlopen(path, RTLD_NOW);
    if (!lib) { printf("  FAIL dlopen(%s): %s\n", path, dlerror()); return 1; }

    SYM(hs_new, "aether_hs_embed_new");
    SYM(hs_free, "aether_hs_embed_free");
    SYM(hs_free_string, "aether_hs_embed_free_string");
    SYM(hs_sanitize, "aether_hs_embed_sanitize");
    SYM(hs_sanitize_document, "aether_hs_embed_sanitize_document");
    SYM(hs_set_keep_child_nodes, "aether_hs_embed_set_keep_child_nodes");
    SYM(hs_set_allow_data_attributes, "aether_hs_embed_set_allow_data_attributes");
    SYM(hs_allow, "aether_hs_embed_allow");
    SYM(hs_disallow, "aether_hs_embed_disallow");
    SYM(hs_is_allowed, "aether_hs_embed_is_allowed");
    SYM(hs_clear, "aether_hs_embed_clear");
    SYM(hs_count, "aether_hs_embed_count");
    SYM(hs_item_at, "aether_hs_embed_item_at");
    SYM(hs_abi_version, "aether_hs_embed_abi_version");
    SYM(hs_on_removing_tag, "aether_hs_embed_on_removing_tag");
    SYM(hs_on_removing_attribute, "aether_hs_embed_on_removing_attribute");
    SYM(hs_on_removing_comment, "aether_hs_embed_on_removing_comment");
    SYM(hs_on_removing_style, "aether_hs_embed_on_removing_style");
    SYM(hs_on_filter_url, "aether_hs_embed_on_filter_url");
    SYM(hs_on_post_process_node, "aether_hs_embed_on_post_process_node");
    SYM(hs_node_kind, "aether_hs_embed_node_kind");
    SYM(hs_node_name, "aether_hs_embed_node_name");
    SYM(hs_attr_name, "aether_hs_embed_attr_name");
    SYM(hs_attr_value, "aether_hs_embed_attr_value");
    printf("=== htmlsanitizer C ABI smoke ===\n");
    check_int("abi_version is 1", hs_abi_version(), 1);

    /* 1. the basic sanitize path */
    {
        void* h = hs_new();
        char* out = hs_sanitize(h, "<div>Hello <script>alert(1)</script> world!</div>", "");
        check_str("script removed", out, "<div>Hello  world!</div>");
        hs_free_string(out);
        hs_free(h);
    }

    /* 2. a null handle must not crash, and returns an owned "" */
    {
        char* out = hs_sanitize(NULL, "<div>x</div>", "");
        check_str("null handle returns empty", out, "");
        hs_free_string(out);
        hs_free(NULL);
        printf("  PASS null handle free is a no-op\n");
    }

    /* 3. allow-list mutation: teach it a custom tag */
    {
        void* h = hs_new();
        char* before = hs_sanitize(h, "<my-widget>x</my-widget>", "");
        check_str("unknown tag dropped by default", before, "");
        hs_free_string(before);

        check_int("allow() returns 1", hs_allow(h, 0 /*tags*/, "my-widget"), 1);
        check_int("is_allowed sees it", hs_is_allowed(h, 0, "my-widget"), 1);
        char* after = hs_sanitize(h, "<my-widget>x</my-widget>", "");
        check_str("custom tag now kept", after, "<my-widget>x</my-widget>");
        hs_free_string(after);

        /* the deny direction */
        check_int("disallow() returns 1", hs_disallow(h, 0, "div"), 1);
        check_int("div no longer allowed", hs_is_allowed(h, 0, "div"), 0);
        char* nodiv = hs_sanitize(h, "<div>x</div>", "");
        check_str("div now stripped", nodiv, "");
        hs_free_string(nodiv);
        hs_free(h);
    }

    /* 4. enumeration — the MapKeys read path */
    {
        void* h = hs_new();
        int n = hs_count(h, 3 /*schemes*/);
        check_int("default schemes count", n, 2);   /* http + https */
        int saw_http = 0, saw_https = 0;
        for (int i = 0; i < n; i++) {
            char* item = hs_item_at(h, 3, i);
            if (item && strcmp(item, "http") == 0) saw_http = 1;
            if (item && strcmp(item, "https") == 0) saw_https = 1;
            hs_free_string(item);
        }
        check_int("enumerated http", saw_http, 1);
        check_int("enumerated https", saw_https, 1);

        /* out-of-range is an owned "" not a crash */
        char* oob = hs_item_at(h, 3, 999);
        check_str("item_at out of range", oob, "");
        hs_free_string(oob);

        /* clear() empties it */
        check_int("clear returns 1", hs_clear(h, 3), 1);
        check_int("count after clear", hs_count(h, 3), 0);
        hs_free(h);
    }

    /* 5. flags */
    {
        void* h = hs_new();
        hs_set_keep_child_nodes(h, 1);
        char* out = hs_sanitize(h, "<div><nope>Hello <span>world</span></nope></div>", "");
        check_str("keep_child_nodes", out, "<div>Hello <span>world</span></div>");
        hs_free_string(out);

        hs_set_allow_data_attributes(h, 1);
        char* d = hs_sanitize(h, "<div data-x=\"1\"></div>", "");
        check_str("allow_data_attributes", d, "<div data-x=\"1\"></div>");
        hs_free_string(d);
        hs_free(h);
    }

    /* 6. callbacks — the trampolines */
    {
        void* h = hs_new();
        hs_on_removing_tag(h, (void*)keep_disallowed_tag, (void*)MARKER);
        char* out = hs_sanitize(h, "<div><keep-me>a</keep-me><drop-me>b</drop-me></div>", "");
        check_str("on_removing_tag cancels selectively", out,
                  "<div><keep-me>a</keep-me></div>");
        hs_free_string(out);
        hs_free(h);
    }

    {
        void* h = hs_new();
        hs_on_removing_attribute(h, (void*)keep_onclick, (void*)MARKER);
        char* out = hs_sanitize(h, "<div onclick=\"alert(1)\">x</div>", "");
        check_str("on_removing_attribute still removes", out, "<div>x</div>");
        check_int("attribute hook fired", attr_hook_calls >= 1, 1);
        hs_free_string(out);
        hs_free(h);
    }

    {
        void* h = hs_new();
        hs_on_removing_comment(h, (void*)keep_comments, (void*)MARKER);
        char* out = hs_sanitize(h, "<div>a<!-- keep -->b</div>", "");
        check_str("on_removing_comment cancels", out, "<div>a<!-- keep -->b</div>");
        hs_free_string(out);
        hs_free(h);
    }

    {
        void* h = hs_new();
        hs_on_removing_style(h, (void*)style_hook, (void*)MARKER);
        char* out = hs_sanitize(h, "<div style=\"-custom-thing: 3; color: red\">x</div>", "");
        /* the hook kept the custom property; color was allowed anyway */
        /* Two serialization agreements with upstream C# are visible here:
         * no trailing semicolon (`a: 1; b: 2`), and colours normalised to
         * AngleSharp's canonical rgba(r, g, b, a). */
        check_str("on_removing_style (4-arg) cancels", out,
                  "<div style=\"-custom-thing: 3; color: rgba(255, 0, 0, 1)\">x</div>");
        check_int("style hook fired", style_hook_calls >= 1, 1);
        hs_free_string(out);
        hs_free(h);
    }

    {
        void* h = hs_new();
        hs_on_filter_url(h, (void*)rewrite_url, (void*)MARKER);
        char* out = hs_sanitize(h, "<img src=\"logo.png\">", "https://example.com");
        check_str("on_filter_url rewrites", out, "<img src=\"https://cdn.example.net/logo.png\">");
        hs_free_string(out);
        hs_free(h);
    }

    {
        void* h = hs_new();
        hs_on_post_process_node(h, (void*)count_nodes, (void*)MARKER);
        char* out = hs_sanitize(h, "<div><span>a</span><span>b</span></div>", "");
        hs_free_string(out);
        check_int("post_process_node visited nodes", post_node_calls > 0, 1);
        hs_free(h);
    }

    /* 7. replacing a hook must not leak or double-free the previous box */
    {
        void* h = hs_new();
        hs_on_removing_tag(h, (void*)keep_disallowed_tag, (void*)MARKER);
        hs_on_removing_tag(h, (void*)keep_disallowed_tag, (void*)MARKER);
        hs_on_removing_tag(h, NULL, NULL);   /* clear it */
        char* out = hs_sanitize(h, "<div><keep-me>a</keep-me></div>", "");
        check_str("hook cleared, tag dropped again", out, "<div></div>");
        hs_free_string(out);
        hs_free(h);
    }

    /* 8. sanitize_document is wired */
    {
        void* h = hs_new();
        char* out = hs_sanitize_document(h, "<div>doc<script>x</script></div>", "");
        check_str("sanitize_document", out, "<html><head></head><body><div>doc</div></body></html>");
        hs_free_string(out);
        hs_free(h);
    }

    /* 9. two handles are independent */
    {
        void* a = hs_new();
        void* b = hs_new();
        hs_allow(a, 0, "only-in-a");
        check_int("handle a knows the tag", hs_is_allowed(a, 0, "only-in-a"), 1);
        check_int("handle b does not", hs_is_allowed(b, 0, "only-in-a"), 0);
        hs_free(a);
        hs_free(b);
    }

    if (failures) {
        printf("=== %d ABI check(s) FAILED ===\n", failures);
        return 1;
    }
    printf("=== all htmlsanitizer ABI checks passed ===\n");
    return 0;
}
