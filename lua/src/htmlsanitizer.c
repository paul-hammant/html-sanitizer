/* lua/src/htmlsanitizer.c — the Lua 5.4 C extension over the HtmlSanitizer
 * C ABI (core/embed.ae).
 *
 * This file is the ONLY place in the Lua binding that knows about the C ABI.
 * Everything above it (lua/src/htmlsanitizer.lua) is idiomatic Lua over these
 * functions. No sanitizer logic lives here or anywhere else in this binding —
 * the sanitizer core is core/htmlsanitizer.ae, shared by every language binding.
 *
 * Lua has no FFI in its standard distribution (LuaJIT's `ffi` is not Lua 5.4),
 * so unlike the ctypes/Fiddle/dart:ffi bindings this one is a real C
 * extension. It still `dlopen`s the sanitizer core rather than linking it, so the
 * same HTMLSANITIZER_LIB resolution order as every other binding applies and
 * one .so serves them all.
 *
 * Build:
 *   cc -O2 -fPIC -shared -I/usr/include/lua5.4 \
 *      src/htmlsanitizer.c -o htmlsanitizer_native.so -ldl
 *
 * ## Naming
 *
 * core/embed.ae names its exports hs_embed_<name>; building with --emit=lib
 * mangles them to aether_hs_embed_<name>. That mangled name is what we dlsym.
 *
 * ## The two ownership rules
 *
 *  1. Every char* the ABI returns is caller-owned and must go back to
 *     aether_hs_embed_free_string. push_owned() below is the only place a
 *     returned string is turned into a Lua string, and it always frees.
 *  2. Node and attribute pointers handed to a callback are borrowed — valid
 *     only for the duration of that callback, because the DOM is freed when
 *     sanitize returns. The Lua userdata wrapping one is stamped with a
 *     generation counter so a retained node errors instead of reading freed
 *     memory.
 *
 * ## Callback ABI
 *
 * Each hook receives the opaque user_data registered alongside it as its
 * FIRST argument. Integer arguments are C `int`, NOT `long` — a host
 * declaring `long` gets a 4-vs-8-byte mismatch on LP64.
 *
 * For the removing_* family a NON-ZERO return CANCELS the removal.
 * filter_url returns a malloc'd C string the sanitizer core takes ownership of.
 */

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>

/* ---- the ABI, dlsym'd once ---- */

typedef void* (*fn_new)(void);
typedef void  (*fn_free)(void*);
typedef void  (*fn_free_string)(char*);
typedef char* (*fn_sanitize)(void*, const char*, const char*);
typedef void  (*fn_set_flag)(void*, int);
typedef int   (*fn_get_flag)(void*);
typedef int   (*fn_set_item)(void*, int, const char*);
typedef int   (*fn_which)(void*, int);
typedef char* (*fn_item_at)(void*, int, int);
typedef int   (*fn_abi_version)(void);
typedef void  (*fn_on_hook)(void*, void*, void*);
typedef int   (*fn_node_int)(void*);
typedef char* (*fn_node_str)(void*);
typedef void* (*fn_node_at)(void*, int);
typedef void* (*fn_node_ptr)(void*);
typedef void  (*fn_attr_set_value)(void*, const char*);

typedef struct {
    void* handle;                     /* the dlopen'd sanitizer core */
    char  path[4096];                 /* where it came from */

    fn_new            hs_new;
    fn_free           hs_free;
    fn_free_string    free_string;
    fn_sanitize       sanitize;
    fn_sanitize       sanitize_document;
    fn_set_flag       set_keep_child_nodes;
    fn_get_flag       get_keep_child_nodes;
    fn_set_flag       set_allow_data_attributes;
    fn_get_flag       get_allow_data_attributes;
    fn_set_item       allow;
    fn_set_item       disallow;
    fn_set_item       is_allowed;
    fn_which          clear;
    fn_which          count;
    fn_item_at        item_at;
    fn_abi_version    abi_version;
    fn_on_hook        on_removing_tag;
    fn_on_hook        on_removing_attribute;
    fn_on_hook        on_removing_style;
    fn_on_hook        on_removing_comment;
    fn_on_hook        on_post_process_node;
    fn_on_hook        on_post_process_dom;
    fn_on_hook        on_filter_url;
    fn_node_int       node_kind;
    fn_node_str       node_name;
    fn_node_str       node_value;
    fn_node_int       node_child_count;
    fn_node_at        node_child_at;
    fn_node_ptr       node_parent;
    fn_node_int       node_attr_count;
    fn_node_at        node_attr_at;
    fn_node_str       attr_name;
    fn_node_str       attr_value;
    fn_attr_set_value attr_set_value;
} Engine;

static Engine ENGINE;                 /* process-wide; loaded once */

/* ---- userdata types ---- */

#define SANITIZER_MT "htmlsanitizer.Sanitizer"
#define NODE_MT      "htmlsanitizer.Node"
#define ATTR_MT      "htmlsanitizer.Attribute"

/* The seven hooks, in the order the ABI declares them. Each Sanitizer keeps
 * its Lua handler functions in the registry, keyed by a per-sanitizer table,
 * so they cannot be collected while the sanitizer core can still call them. */
enum {
    HOOK_REMOVING_TAG = 0,
    HOOK_REMOVING_ATTRIBUTE,
    HOOK_REMOVING_STYLE,
    HOOK_REMOVING_COMMENT,
    HOOK_POST_PROCESS_NODE,
    HOOK_POST_PROCESS_DOM,
    HOOK_FILTER_URL,
    HOOK_COUNT
};

typedef struct Sanitizer {
    void*        h;             /* the sanitizer core handle; NULL once closed */
    lua_State*   L;             /* the state that owns this sanitizer */
    int          hooks_ref;     /* LUA_REGISTRYINDEX ref to the handler table */
    unsigned int generation;    /* bumped per sanitize() — see NodeRef */
    int          in_sanitize;   /* re-entrancy guard */
} Sanitizer;

/* A borrowed DOM pointer, stamped with the generation it was handed out in.
 * Reading one after sanitize() returned is a use-after-free in every other
 * binding; here it is a clean Lua error. */
typedef struct {
    void*        p;
    Sanitizer*   owner;
    unsigned int generation;
} NodeRef;

/* ---- sanitizer core loading ---- */

static int load_symbols(lua_State* L, void* lib, const char* path) {
#define SYM(field, name)                                                   \
    do {                                                                   \
        *(void**)(&ENGINE.field) = dlsym(lib, name);                       \
        if (!ENGINE.field) {                                               \
            dlclose(lib);                                                  \
            memset(&ENGINE, 0, sizeof(ENGINE));                            \
            return luaL_error(L, "htmlsanitizer: sanitizer core at '%s' is missing "\
                                 "symbol %s", path, name);                 \
        }                                                                  \
    } while (0)

    SYM(hs_new,                    "aether_hs_embed_new");
    SYM(hs_free,                   "aether_hs_embed_free");
    SYM(free_string,               "aether_hs_embed_free_string");
    SYM(sanitize,                  "aether_hs_embed_sanitize");
    SYM(sanitize_document,         "aether_hs_embed_sanitize_document");
    SYM(set_keep_child_nodes,      "aether_hs_embed_set_keep_child_nodes");
    SYM(get_keep_child_nodes,      "aether_hs_embed_get_keep_child_nodes");
    SYM(set_allow_data_attributes, "aether_hs_embed_set_allow_data_attributes");
    SYM(get_allow_data_attributes, "aether_hs_embed_get_allow_data_attributes");
    SYM(allow,                     "aether_hs_embed_allow");
    SYM(disallow,                  "aether_hs_embed_disallow");
    SYM(is_allowed,                "aether_hs_embed_is_allowed");
    SYM(clear,                     "aether_hs_embed_clear");
    SYM(count,                     "aether_hs_embed_count");
    SYM(item_at,                   "aether_hs_embed_item_at");
    SYM(abi_version,               "aether_hs_embed_abi_version");
    SYM(on_removing_tag,           "aether_hs_embed_on_removing_tag");
    SYM(on_removing_attribute,     "aether_hs_embed_on_removing_attribute");
    SYM(on_removing_style,         "aether_hs_embed_on_removing_style");
    SYM(on_removing_comment,       "aether_hs_embed_on_removing_comment");
    SYM(on_post_process_node,      "aether_hs_embed_on_post_process_node");
    SYM(on_post_process_dom,       "aether_hs_embed_on_post_process_dom");
    SYM(on_filter_url,             "aether_hs_embed_on_filter_url");
    SYM(node_kind,                 "aether_hs_embed_node_kind");
    SYM(node_name,                 "aether_hs_embed_node_name");
    SYM(node_value,                "aether_hs_embed_node_value");
    SYM(node_child_count,          "aether_hs_embed_node_child_count");
    SYM(node_child_at,             "aether_hs_embed_node_child_at");
    SYM(node_parent,               "aether_hs_embed_node_parent");
    SYM(node_attr_count,           "aether_hs_embed_node_attr_count");
    SYM(node_attr_at,              "aether_hs_embed_node_attr_at");
    SYM(attr_name,                 "aether_hs_embed_attr_name");
    SYM(attr_value,                "aether_hs_embed_attr_value");
    SYM(attr_set_value,            "aether_hs_embed_attr_set_value");
#undef SYM

    ENGINE.handle = lib;
    snprintf(ENGINE.path, sizeof(ENGINE.path), "%s", path);
    return 0;
}

/* Candidates, in resolution order:
 *   1. an explicit path passed to load()
 *   2. $HTMLSANITIZER_LIB
 *   3. native/ next to this extension, then ../core/native/
 *   4. the OS loader's own search path
 */
static int engine_load(lua_State* L, const char* explicit_path) {
    if (ENGINE.handle && !explicit_path) return 0;

    const char* candidates[8];
    int n = 0;
    char buf1[4096], buf2[4096];

    if (explicit_path && *explicit_path) {
        candidates[n++] = explicit_path;
    } else {
        const char* env = getenv("HTMLSANITIZER_LIB");
        if (env && *env) candidates[n++] = env;
        snprintf(buf1, sizeof(buf1), "native/libhtmlsanitizer.so");
        candidates[n++] = buf1;
        snprintf(buf2, sizeof(buf2), "../core/native/libhtmlsanitizer.so");
        candidates[n++] = buf2;
        candidates[n++] = "libhtmlsanitizer.so";
    }

    const char* last_err = "(none)";
    for (int i = 0; i < n; i++) {
        void* lib = dlopen(candidates[i], RTLD_NOW | RTLD_LOCAL);
        if (lib) return load_symbols(L, lib, candidates[i]);
        const char* e = dlerror();
        if (e) last_err = e;
    }
    return luaL_error(L,
        "htmlsanitizer: could not load the sanitizer core (libhtmlsanitizer.so). Set "
        "HTMLSANITIZER_LIB to its absolute path, or build it with:\n"
        "  cd core && ae build --emit=lib embed.ae --extra _embed_support.c "
        "-o native/libhtmlsanitizer.so\nLast dlerror: %s", last_err);
}

/* ---- string helpers ---- */

/* Push an ABI-returned string and FREE it. Every char* out of the sanitizer core is
 * caller-owned; this is the single place that ownership is discharged. */
static void push_owned(lua_State* L, char* s) {
    if (!s) { lua_pushliteral(L, ""); return; }
    lua_pushstring(L, s);
    ENGINE.free_string(s);
}

/* ---- Sanitizer ---- */

static Sanitizer* check_sanitizer(lua_State* L, int idx) {
    Sanitizer* s = (Sanitizer*)luaL_checkudata(L, idx, SANITIZER_MT);
    if (!s->h) luaL_error(L, "htmlsanitizer: sanitizer is closed");
    return s;
}

/* The per-sanitizer table of Lua handlers, pushed onto the stack. */
static void push_hooks(lua_State* L, Sanitizer* s) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, s->hooks_ref);
}

static int l_new(lua_State* L) {
    const char* path = luaL_optstring(L, 1, NULL);
    engine_load(L, path);

    Sanitizer* s = (Sanitizer*)lua_newuserdatauv(L, sizeof(Sanitizer), 0);
    memset(s, 0, sizeof(*s));
    s->L = L;
    s->generation = 1;
    s->hooks_ref = LUA_NOREF;
    luaL_setmetatable(L, SANITIZER_MT);

    s->h = ENGINE.hs_new();
    if (!s->h) return luaL_error(L, "htmlsanitizer: failed to create the "
                                   "native sanitizer");

    /* The handler table. Anchored in the registry so the Lua functions
     * survive as long as the sanitizer core can call them — the Lua equivalent of
     * ctypes' keepalive list. */
    lua_newtable(L);
    s->hooks_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    return 1;
}

static int l_close(lua_State* L) {
    Sanitizer* s = (Sanitizer*)luaL_checkudata(L, 1, SANITIZER_MT);
    if (s->h) {
        ENGINE.hs_free(s->h);
        s->h = NULL;
    }
    if (s->hooks_ref != LUA_NOREF) {
        luaL_unref(L, LUA_REGISTRYINDEX, s->hooks_ref);
        s->hooks_ref = LUA_NOREF;
    }
    /* Invalidate every NodeRef ever handed out by this sanitizer. */
    s->generation++;
    return 0;
}

static int l_gc(lua_State* L) { return l_close(L); }

static int sanitize_with(lua_State* L, fn_sanitize fn) {
    Sanitizer* s = check_sanitizer(L, 1);
    const char* html = luaL_checkstring(L, 2);
    const char* base = luaL_optstring(L, 3, "");

    if (s->in_sanitize) {
        return luaL_error(L, "htmlsanitizer: sanitize() re-entered from a "
                             "callback");
    }
    s->in_sanitize = 1;
    char* out = fn(s->h, html, base);
    s->in_sanitize = 0;
    /* The DOM this call built is gone; poison any NodeRef that escaped. */
    s->generation++;

    push_owned(L, out);
    return 1;
}

static int l_sanitize(lua_State* L) { return sanitize_with(L, ENGINE.sanitize); }
static int l_sanitize_document(lua_State* L) {
    return sanitize_with(L, ENGINE.sanitize_document);
}

/* ---- flags ---- */

static int l_set_keep_child_nodes(lua_State* L) {
    Sanitizer* s = check_sanitizer(L, 1);
    luaL_checkany(L, 2);
    ENGINE.set_keep_child_nodes(s->h, lua_toboolean(L, 2));
    return 0;
}

static int l_get_keep_child_nodes(lua_State* L) {
    Sanitizer* s = check_sanitizer(L, 1);
    lua_pushboolean(L, ENGINE.get_keep_child_nodes(s->h));
    return 1;
}

static int l_set_allow_data_attributes(lua_State* L) {
    Sanitizer* s = check_sanitizer(L, 1);
    luaL_checkany(L, 2);
    ENGINE.set_allow_data_attributes(s->h, lua_toboolean(L, 2));
    return 0;
}

static int l_get_allow_data_attributes(lua_State* L) {
    Sanitizer* s = check_sanitizer(L, 1);
    lua_pushboolean(L, ENGINE.get_allow_data_attributes(s->h));
    return 1;
}

static int l_abi_version(lua_State* L) {
    engine_load(L, NULL);
    lua_pushinteger(L, ENGINE.abi_version());
    return 1;
}

static int l_engine_path(lua_State* L) {
    engine_load(L, NULL);
    lua_pushstring(L, ENGINE.path);
    return 1;
}

/* ---- allow-lists (the `which` selector crosses as an integer) ---- */

static int check_which(lua_State* L, int idx) {
    int which = (int)luaL_checkinteger(L, idx);
    if (which < 0 || which > 5) {
        luaL_error(L, "htmlsanitizer: bad allow-list selector %d (0..5)", which);
    }
    return which;
}

static int l_allow(lua_State* L) {
    Sanitizer* s = check_sanitizer(L, 1);
    int which = check_which(L, 2);
    lua_pushboolean(L, ENGINE.allow(s->h, which, luaL_checkstring(L, 3)));
    return 1;
}

static int l_disallow(lua_State* L) {
    Sanitizer* s = check_sanitizer(L, 1);
    int which = check_which(L, 2);
    lua_pushboolean(L, ENGINE.disallow(s->h, which, luaL_checkstring(L, 3)));
    return 1;
}

static int l_is_allowed(lua_State* L) {
    Sanitizer* s = check_sanitizer(L, 1);
    int which = check_which(L, 2);
    lua_pushboolean(L, ENGINE.is_allowed(s->h, which, luaL_checkstring(L, 3)));
    return 1;
}

static int l_clear(lua_State* L) {
    Sanitizer* s = check_sanitizer(L, 1);
    lua_pushboolean(L, ENGINE.clear(s->h, check_which(L, 2)));
    return 1;
}

static int l_count(lua_State* L) {
    Sanitizer* s = check_sanitizer(L, 1);
    lua_pushinteger(L, ENGINE.count(s->h, check_which(L, 2)));
    return 1;
}

static int l_item_at(lua_State* L) {
    Sanitizer* s = check_sanitizer(L, 1);
    int which = check_which(L, 2);
    /* Lua is 1-based; the ABI is 0-based. The conversion lives here so the
     * Lua surface above never sees a 0-based index. */
    lua_Integer i = luaL_checkinteger(L, 3);
    push_owned(L, ENGINE.item_at(s->h, which, (int)(i - 1)));
    return 1;
}

/* ---- Node / Attribute userdata ---- */

static void push_ref(lua_State* L, Sanitizer* owner, void* p, const char* mt) {
    if (!p) { lua_pushnil(L); return; }
    NodeRef* r = (NodeRef*)lua_newuserdatauv(L, sizeof(NodeRef), 0);
    r->p = p;
    r->owner = owner;
    r->generation = owner->generation;
    luaL_setmetatable(L, mt);
}

static NodeRef* check_ref(lua_State* L, int idx, const char* mt) {
    NodeRef* r = (NodeRef*)luaL_checkudata(L, idx, mt);
    if (!r->owner->h || r->generation != r->owner->generation) {
        luaL_error(L, "htmlsanitizer: this %s was borrowed for the duration "
                      "of a callback and is no longer valid (the DOM is freed "
                      "when sanitize() returns)", mt);
    }
    return r;
}

static int l_node_kind(lua_State* L) {
    lua_pushinteger(L, ENGINE.node_kind(check_ref(L, 1, NODE_MT)->p));
    return 1;
}

static int l_node_name(lua_State* L) {
    push_owned(L, ENGINE.node_name(check_ref(L, 1, NODE_MT)->p));
    return 1;
}

static int l_node_value(lua_State* L) {
    push_owned(L, ENGINE.node_value(check_ref(L, 1, NODE_MT)->p));
    return 1;
}

static int l_node_child_count(lua_State* L) {
    lua_pushinteger(L, ENGINE.node_child_count(check_ref(L, 1, NODE_MT)->p));
    return 1;
}

static int l_node_child_at(lua_State* L) {
    NodeRef* r = check_ref(L, 1, NODE_MT);
    lua_Integer i = luaL_checkinteger(L, 2);
    push_ref(L, r->owner, ENGINE.node_child_at(r->p, (int)(i - 1)), NODE_MT);
    return 1;
}

static int l_node_parent(lua_State* L) {
    NodeRef* r = check_ref(L, 1, NODE_MT);
    push_ref(L, r->owner, ENGINE.node_parent(r->p), NODE_MT);
    return 1;
}

static int l_node_attr_count(lua_State* L) {
    lua_pushinteger(L, ENGINE.node_attr_count(check_ref(L, 1, NODE_MT)->p));
    return 1;
}

static int l_node_attr_at(lua_State* L) {
    NodeRef* r = check_ref(L, 1, NODE_MT);
    lua_Integer i = luaL_checkinteger(L, 2);
    push_ref(L, r->owner, ENGINE.node_attr_at(r->p, (int)(i - 1)), ATTR_MT);
    return 1;
}

static int l_attr_name(lua_State* L) {
    push_owned(L, ENGINE.attr_name(check_ref(L, 1, ATTR_MT)->p));
    return 1;
}

static int l_attr_value(lua_State* L) {
    push_owned(L, ENGINE.attr_value(check_ref(L, 1, ATTR_MT)->p));
    return 1;
}

static int l_attr_set_value(lua_State* L) {
    NodeRef* r = check_ref(L, 1, ATTR_MT);
    /* aether_hs_embed_attr_set_value COPIES core-side, so handing it Lua's
     * own (collectable) string buffer is safe. */
    ENGINE.attr_set_value(r->p, luaL_checkstring(L, 2));
    return 0;
}

/* ---- callback trampolines ----
 *
 * user_data is the Sanitizer*, so a trampoline can find the lua_State and the
 * registry-anchored handler table. Every integer is C `int`.
 *
 * A Lua error inside a handler must not longjmp across the sanitizer core's C frames,
 * so each trampoline calls the handler with lua_pcall and, on error, falls
 * back to the safe default: "let the removal proceed" / "no URL rewrite".
 */

/* Push hooks[slot] and the Sanitizer's state; returns 0 if no handler. */
static int begin_call(Sanitizer* s, lua_State** out_L, int slot) {
    lua_State* L = s->L;
    if (!L || s->hooks_ref == LUA_NOREF) return 0;
    push_hooks(L, s);
    lua_rawgeti(L, -1, slot + 1);
    if (!lua_isfunction(L, -1)) { lua_pop(L, 2); return 0; }
    lua_remove(L, -2);              /* drop the hooks table, keep the fn */
    *out_L = L;
    return 1;
}

/* pcall with `nargs` on the stack, expecting `nres` results. Returns 1 on
 * success (results on the stack), 0 on error (message already discarded). */
static int finish_call(lua_State* L, int nargs, int nres) {
    if (lua_pcall(L, nargs, nres, 0) != LUA_OK) {
        /* Swallowing is deliberate: there is no Lua frame to propagate to
         * from inside a sanitizer core C callback. Surface it on stderr so a broken
         * handler is not silent. */
        const char* msg = lua_tostring(L, -1);
        fprintf(stderr, "htmlsanitizer: error in callback: %s\n",
                msg ? msg : "(non-string error)");
        lua_pop(L, 1);
        return 0;
    }
    return 1;
}

static int cb_removing_tag(void* ud, void* node, int reason) {
    Sanitizer* s = (Sanitizer*)ud;
    lua_State* L;
    if (!begin_call(s, &L, HOOK_REMOVING_TAG)) return 0;
    push_ref(L, s, node, NODE_MT);
    lua_pushinteger(L, reason);
    if (!finish_call(L, 2, 1)) return 0;
    int keep = lua_toboolean(L, -1);
    lua_pop(L, 1);
    return keep;                     /* non-zero CANCELS the removal */
}

static int cb_removing_attribute(void* ud, void* elem, void* attr, int reason) {
    Sanitizer* s = (Sanitizer*)ud;
    lua_State* L;
    if (!begin_call(s, &L, HOOK_REMOVING_ATTRIBUTE)) return 0;
    push_ref(L, s, elem, NODE_MT);
    push_ref(L, s, attr, ATTR_MT);
    lua_pushinteger(L, reason);
    if (!finish_call(L, 3, 1)) return 0;
    int keep = lua_toboolean(L, -1);
    lua_pop(L, 1);
    return keep;
}

static int cb_removing_style(void* ud, void* elem, const char* name,
                             const char* value, int reason) {
    Sanitizer* s = (Sanitizer*)ud;
    lua_State* L;
    if (!begin_call(s, &L, HOOK_REMOVING_STYLE)) return 0;
    push_ref(L, s, elem, NODE_MT);
    /* name/value are BORROWED const char* — the sanitizer core owns them; copy into
     * Lua strings, never free. */
    lua_pushstring(L, name ? name : "");
    lua_pushstring(L, value ? value : "");
    lua_pushinteger(L, reason);
    if (!finish_call(L, 4, 1)) return 0;
    int keep = lua_toboolean(L, -1);
    lua_pop(L, 1);
    return keep;
}

static int cb_removing_comment(void* ud, void* node) {
    Sanitizer* s = (Sanitizer*)ud;
    lua_State* L;
    if (!begin_call(s, &L, HOOK_REMOVING_COMMENT)) return 0;
    push_ref(L, s, node, NODE_MT);
    if (!finish_call(L, 1, 1)) return 0;
    int keep = lua_toboolean(L, -1);
    lua_pop(L, 1);
    return keep;
}

static void cb_post_process_node(void* ud, void* node) {
    Sanitizer* s = (Sanitizer*)ud;
    lua_State* L;
    if (!begin_call(s, &L, HOOK_POST_PROCESS_NODE)) return;
    push_ref(L, s, node, NODE_MT);
    finish_call(L, 1, 0);
}

static void cb_post_process_dom(void* ud, void* doc) {
    Sanitizer* s = (Sanitizer*)ud;
    lua_State* L;
    if (!begin_call(s, &L, HOOK_POST_PROCESS_DOM)) return;
    push_ref(L, s, doc, NODE_MT);
    finish_call(L, 1, 0);
}

static char* cb_filter_url(void* ud, void* elem, const char* raw,
                           const char* resolved) {
    Sanitizer* s = (Sanitizer*)ud;
    lua_State* L;
    /* "No rewrite" is the `resolved` pointer returned unchanged. */
    if (!begin_call(s, &L, HOOK_FILTER_URL)) return (char*)resolved;
    push_ref(L, s, elem, NODE_MT);
    lua_pushstring(L, raw ? raw : "");
    lua_pushstring(L, resolved ? resolved : "");
    if (!finish_call(L, 3, 1)) return (char*)resolved;

    const char* out = lua_tostring(L, -1);
    char* dup = out ? strdup(out) : (char*)NULL;
    lua_pop(L, 1);
    /* The sanitizer core takes ownership of what we return; a nil/failed strdup means
     * "no rewrite". */
    return dup ? dup : (char*)resolved;
}

/* ---- hook registration ----
 *
 * The (void*) casts on the trampolines below are ISO-C-forbidden conversions
 * of a function pointer to an object pointer (-Wpedantic says so), but they
 * are exactly what this ABI requires — hs_embed_on_*() takes the host
 * callback as void*, and dlsym() has the same shape in reverse. POSIX
 * guarantees the round trip, and core_tests/abi_smoke.c does the same thing.
 * The build is clean under -Wall -Wextra; only -Wpedantic objects.
 */

static int register_hook(lua_State* L, int slot, fn_on_hook reg,
                         void* trampoline) {
    Sanitizer* s = check_sanitizer(L, 1);

    push_hooks(L, s);                  /* [hooks] */
    if (lua_isnoneornil(L, 2)) {
        lua_pushnil(L);
        lua_rawseti(L, -2, slot + 1);
        lua_pop(L, 1);
        reg(s->h, NULL, NULL);
        return 0;
    }
    luaL_checktype(L, 2, LUA_TFUNCTION);
    lua_pushvalue(L, 2);               /* [hooks][fn] */
    lua_rawseti(L, -2, slot + 1);      /* [hooks] — anchored, cannot be GC'd */
    lua_pop(L, 1);

    /* user_data is the Sanitizer*, round-tripped by the sanitizer core's trampoline
     * and handed back as each callback's FIRST argument. */
    reg(s->h, trampoline, s);
    return 0;
}

static int l_on_removing_tag(lua_State* L) {
    return register_hook(L, HOOK_REMOVING_TAG, ENGINE.on_removing_tag,
                         (void*)cb_removing_tag);
}
static int l_on_removing_attribute(lua_State* L) {
    return register_hook(L, HOOK_REMOVING_ATTRIBUTE,
                         ENGINE.on_removing_attribute,
                         (void*)cb_removing_attribute);
}
static int l_on_removing_style(lua_State* L) {
    return register_hook(L, HOOK_REMOVING_STYLE, ENGINE.on_removing_style,
                         (void*)cb_removing_style);
}
static int l_on_removing_comment(lua_State* L) {
    return register_hook(L, HOOK_REMOVING_COMMENT, ENGINE.on_removing_comment,
                         (void*)cb_removing_comment);
}
static int l_on_post_process_node(lua_State* L) {
    return register_hook(L, HOOK_POST_PROCESS_NODE,
                         ENGINE.on_post_process_node,
                         (void*)cb_post_process_node);
}
static int l_on_post_process_dom(lua_State* L) {
    return register_hook(L, HOOK_POST_PROCESS_DOM, ENGINE.on_post_process_dom,
                         (void*)cb_post_process_dom);
}
static int l_on_filter_url(lua_State* L) {
    return register_hook(L, HOOK_FILTER_URL, ENGINE.on_filter_url,
                         (void*)cb_filter_url);
}

/* ---- module table ---- */

static const luaL_Reg SANITIZER_METHODS[] = {
    {"sanitize",                  l_sanitize},
    {"sanitize_document",         l_sanitize_document},
    {"close",                     l_close},
    {"allow",                     l_allow},
    {"disallow",                  l_disallow},
    {"is_allowed",                l_is_allowed},
    {"clear",                     l_clear},
    {"count",                     l_count},
    {"item_at",                   l_item_at},
    {"set_keep_child_nodes",      l_set_keep_child_nodes},
    {"get_keep_child_nodes",      l_get_keep_child_nodes},
    {"set_allow_data_attributes", l_set_allow_data_attributes},
    {"get_allow_data_attributes", l_get_allow_data_attributes},
    {"on_removing_tag",           l_on_removing_tag},
    {"on_removing_attribute",     l_on_removing_attribute},
    {"on_removing_style",         l_on_removing_style},
    {"on_removing_comment",       l_on_removing_comment},
    {"on_post_process_node",      l_on_post_process_node},
    {"on_post_process_dom",       l_on_post_process_dom},
    {"on_filter_url",             l_on_filter_url},
    {NULL, NULL}
};

static const luaL_Reg NODE_METHODS[] = {
    {"kind",        l_node_kind},
    {"name",        l_node_name},
    {"value",       l_node_value},
    {"child_count", l_node_child_count},
    {"child_at",    l_node_child_at},
    {"parent",      l_node_parent},
    {"attr_count",  l_node_attr_count},
    {"attr_at",     l_node_attr_at},
    {NULL, NULL}
};

static const luaL_Reg ATTR_METHODS[] = {
    {"name",      l_attr_name},
    {"value",     l_attr_value},
    {"set_value", l_attr_set_value},
    {NULL, NULL}
};

static const luaL_Reg MODULE[] = {
    {"new",         l_new},
    {"abi_version", l_abi_version},
    {"engine_path", l_engine_path},
    {NULL, NULL}
};

static void make_class(lua_State* L, const char* mt, const luaL_Reg* methods,
                       lua_CFunction gc) {
    luaL_newmetatable(L, mt);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    luaL_setfuncs(L, methods, 0);
    if (gc) {
        lua_pushcfunction(L, gc);
        lua_setfield(L, -2, "__gc");
    }
    lua_pushstring(L, mt);
    lua_setfield(L, -2, "__name");
    lua_pop(L, 1);
}

int luaopen_htmlsanitizer_native(lua_State* L) {
    make_class(L, SANITIZER_MT, SANITIZER_METHODS, l_gc);
    make_class(L, NODE_MT, NODE_METHODS, NULL);
    make_class(L, ATTR_MT, ATTR_METHODS, NULL);

    luaL_newlib(L, MODULE);

    /* ABI constants — append only, never renumber. */
#define K(name, value) \
    do { lua_pushinteger(L, (value)); lua_setfield(L, -2, name); } while (0)
    K("TAGS", 0);
    K("ATTRIBUTES", 1);
    K("CSS_PROPERTIES", 2);
    K("SCHEMES", 3);
    K("CLASSES", 4);
    K("URI_ATTRIBUTES", 5);

    K("REASON_NOT_ALLOWED_TAG", 0);
    K("REASON_NOT_ALLOWED_ATTRIBUTE", 1);
    K("REASON_NOT_ALLOWED_STYLE", 2);
    K("REASON_NOT_ALLOWED_URL_VALUE", 3);
    K("REASON_NOT_ALLOWED_VALUE", 4);
    K("REASON_NOT_ALLOWED_CSS_CLASS", 5);
    K("REASON_CLASS_ATTRIBUTE_EMPTY", 6);
    K("REASON_STYLE_ATTRIBUTE_EMPTY", 7);

    K("NODE_DOCUMENT", 1);
    K("NODE_ELEMENT", 2);
    K("NODE_TEXT", 3);
    K("NODE_COMMENT", 4);
#undef K

    return 1;
}
