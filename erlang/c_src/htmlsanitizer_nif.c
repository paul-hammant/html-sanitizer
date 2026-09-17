/* erlang/c_src/htmlsanitizer_nif.c — the canonical BEAM binding.
 *
 * ONE NIF, shared by all three BEAM languages. Erlang loads it directly;
 * Elixir `defdelegate`s to it; Gleam reaches it with `@external(erlang, ...)`.
 * There is no second copy of this file anywhere in the monorepo — elixir/ and
 * gleam/ build.dep the erlang/ node and load THIS compiled module over the
 * BEAM, found via ERL_LIBS.
 *
 * NO SANITIZER LOGIC LIVES HERE. Every function marshals BEAM terms to an
 * `aether_hs_embed_*` call across the C ABI described in core/embed.ae. The
 * sanitizer core (core/htmlsanitizer.ae) is pure Aether.
 *
 * ## The two ownership rules
 *
 *  1. Every char* the ABI returns is CALLER-OWNED and must go back through
 *     aether_hs_embed_free_string. `take_binary` below is the only path a
 *     returned string takes out of this file, so the free cannot be forgotten.
 *  2. Node/attr pointers handed to a callback are borrowed. We register no
 *     callbacks at all (see below), so that rule never bites us here.
 *
 * ## Why there are no callbacks (conformance checks 10 and 11)
 *
 * The sanitizer core's hooks are C function pointers invoked SYNCHRONOUSLY from
 * inside aether_hs_embed_sanitize. To honour one in Erlang we would have to
 * call back into the BEAM from the middle of a NIF: send a message to a
 * process and block the NIF's scheduler thread waiting for the reply. That
 * deadlocks the moment the owning process is itself the caller, and it stalls
 * a scheduler regardless. `enif_send` from a NIF is one-way — there is no safe
 * synchronous "call a process and wait" primitive. So this binding registers
 * NO hooks and the BEAM family skips conformance checks 10 and 11. That is
 * documented in erlang/README.md, elixir/README.md and gleam/README.md. The
 * other ten checks are covered in full, and the hook surface is simply absent
 * rather than faked.
 *
 * ## Handle lifetime
 *
 * A sanitizer is an enif_resource. The GC frees the native handle when the
 * last BEAM reference to the resource goes away, so a caller who forgets
 * close/1 leaks nothing. close/1 makes the release deterministic and marks
 * the resource closed so later use returns {error, closed} rather than
 * dereferencing a freed pointer.
 *
 * ## Dirty schedulers
 *
 * sanitize/3 parses arbitrary HTML and can run well past the 1ms a normal NIF
 * is allowed, which would degrade BEAM scheduler fairness. Both sanitize
 * entry points are therefore flagged ERL_NIF_DIRTY_JOB_CPU_BOUND.
 */
#include <erl_nif.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#ifdef _WIN32
#  include <windows.h>
#  define HS_DLOPEN(p)      ((void *)LoadLibraryA(p))
#  define HS_DLSYM(h, n)    ((void *)GetProcAddress((HMODULE)(h), (n)))
#  define HS_LIB_NAME       "htmlsanitizer.dll"
#else
#  include <dlfcn.h>
#  define HS_DLOPEN(p)      dlopen((p), RTLD_NOW | RTLD_LOCAL)
#  define HS_DLSYM(h, n)    dlsym((h), (n))
#  ifdef __APPLE__
#    define HS_LIB_NAME     "libhtmlsanitizer.dylib"
#  else
#    define HS_LIB_NAME     "libhtmlsanitizer.so"
#  endif
#endif

/* ---- the C ABI (core/embed.ae), resolved once at load ---- */

static void *(*hs_new)(void);
static void  (*hs_free)(void *);
static void  (*hs_free_string)(char *);
static char *(*hs_sanitize)(void *, const char *, const char *);
static char *(*hs_sanitize_document)(void *, const char *, const char *);
static void  (*hs_set_keep_child_nodes)(void *, int);
static int   (*hs_get_keep_child_nodes)(void *);
static void  (*hs_set_allow_data_attributes)(void *, int);
static int   (*hs_get_allow_data_attributes)(void *);
static int   (*hs_allow)(void *, int, const char *);
static int   (*hs_disallow)(void *, int, const char *);
static int   (*hs_is_allowed)(void *, int, const char *);
static int   (*hs_clear)(void *, int);
static int   (*hs_count)(void *, int);
static char *(*hs_item_at)(void *, int, int);
static int   (*hs_abi_version)(void);

static void *hs_lib = NULL;

/* ---- atoms ---- */

static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;
static ERL_NIF_TERM atom_true;
static ERL_NIF_TERM atom_false;
static ERL_NIF_TERM atom_closed;
static ERL_NIF_TERM atom_badarg;
static ERL_NIF_TERM atom_alloc_failed;

/* ---- the sanitizer resource ---- */

typedef struct {
    void *handle;   /* the sanitizer core's opaque *HtmlSanitizer; NULL once closed */
} hs_res;

static ErlNifResourceType *HS_RES_TYPE = NULL;

/* The GC's last-reference hook. A caller who never calls close/1 still frees
 * the native handle here, so a dropped sanitizer cannot leak the sanitizer core's
 * allocation. */
static void hs_res_dtor(ErlNifEnv *env, void *obj)
{
    hs_res *r = (hs_res *)obj;
    (void)env;
    if (r->handle) {
        hs_free(r->handle);
        r->handle = NULL;
    }
}

/* ---- small helpers ---- */

/* Copy a BEAM binary/iolist argument into a NUL-terminated C string.
 *
 * The sanitizer core's ABI is NUL-terminated char*, so a binary containing an interior
 * NUL cannot be represented; we truncate at it rather than pass a buffer whose
 * C length disagrees with its BEAM length. Returns NULL on a bad term or OOM;
 * the caller frees with enif_free. */
static char *term_to_cstr(ErlNifEnv *env, ERL_NIF_TERM term)
{
    ErlNifBinary bin;
    char *out;

    if (!enif_inspect_iolist_as_binary(env, term, &bin)) {
        return NULL;
    }
    out = (char *)enif_alloc(bin.size + 1);
    if (!out) {
        return NULL;
    }
    if (bin.size) {
        memcpy(out, bin.data, bin.size);
    }
    out[bin.size] = '\0';
    return out;
}

/* Turn an ABI-returned, caller-owned char* into a BEAM binary and free it
 * through the ABI. EVERY string result from the sanitizer core goes through here —
 * that is what makes the free impossible to forget. */
static ERL_NIF_TERM take_binary(ErlNifEnv *env, char *s)
{
    ERL_NIF_TERM out;
    size_t len;
    unsigned char *buf;

    if (!s) {
        /* An empty binary, not a crash. The ABI never actually returns NULL
         * (it returns an owned "" instead), but a defensive branch here costs
         * nothing and keeps a future ABI change from segfaulting the VM. */
        enif_make_new_binary(env, 0, &out);
        return out;
    }
    len = strlen(s);
    buf = enif_make_new_binary(env, len, &out);
    if (buf && len) {
        memcpy(buf, s, len);
    }
    hs_free_string(s);
    return out;
}

/* Pull the resource out of argv[0], rejecting a closed handle. */
static int get_res(ErlNifEnv *env, ERL_NIF_TERM term, hs_res **out)
{
    hs_res *r;
    if (!enif_get_resource(env, term, HS_RES_TYPE, (void **)&r)) {
        return 0;
    }
    *out = r;
    return 1;
}

static ERL_NIF_TERM err(ErlNifEnv *env, ERL_NIF_TERM reason)
{
    return enif_make_tuple2(env, atom_error, reason);
}

static ERL_NIF_TERM bool_term(int v) { return v ? atom_true : atom_false; }

/* ---- lifecycle ---- */

static ERL_NIF_TERM nif_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    hs_res *r;
    ERL_NIF_TERM term;
    void *h;
    (void)argc; (void)argv;

    h = hs_new();
    if (!h) {
        return err(env, atom_alloc_failed);
    }
    r = (hs_res *)enif_alloc_resource(HS_RES_TYPE, sizeof(hs_res));
    if (!r) {
        hs_free(h);
        return err(env, atom_alloc_failed);
    }
    r->handle = h;
    term = enif_make_resource(env, r);
    /* The BEAM term now holds the only reference we want to keep. */
    enif_release_resource(r);
    return enif_make_tuple2(env, atom_ok, term);
}

static ERL_NIF_TERM nif_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    hs_res *r;
    (void)argc;

    if (!get_res(env, argv[0], &r)) {
        return enif_make_badarg(env);
    }
    if (r->handle) {
        hs_free(r->handle);
        r->handle = NULL;
    }
    return atom_ok;
}

static ERL_NIF_TERM nif_is_closed(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    hs_res *r;
    (void)argc;

    if (!get_res(env, argv[0], &r)) {
        return enif_make_badarg(env);
    }
    return bool_term(r->handle == NULL);
}

/* ---- sanitize ---- */

/* Shared body for sanitize/3 and sanitize_document/3 — they differ only in
 * which ABI entry point they call. */
static ERL_NIF_TERM do_sanitize(ErlNifEnv *env, const ERL_NIF_TERM argv[],
                                char *(*fn)(void *, const char *, const char *))
{
    hs_res *r;
    char *html, *base, *out;
    ERL_NIF_TERM result;

    if (!get_res(env, argv[0], &r)) {
        return enif_make_badarg(env);
    }
    if (!r->handle) {
        return err(env, atom_closed);
    }
    html = term_to_cstr(env, argv[1]);
    if (!html) {
        return enif_make_badarg(env);
    }
    base = term_to_cstr(env, argv[2]);
    if (!base) {
        enif_free(html);
        return enif_make_badarg(env);
    }
    out = fn(r->handle, html, base);
    enif_free(html);
    enif_free(base);
    result = take_binary(env, out);
    return enif_make_tuple2(env, atom_ok, result);
}

static ERL_NIF_TERM nif_sanitize(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    return do_sanitize(env, argv, hs_sanitize);
}

static ERL_NIF_TERM nif_sanitize_document(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    return do_sanitize(env, argv, hs_sanitize_document);
}

/* ---- flags ---- */

static ERL_NIF_TERM nif_set_keep_child_nodes(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    hs_res *r;
    (void)argc;

    if (!get_res(env, argv[0], &r)) return enif_make_badarg(env);
    if (!r->handle) return err(env, atom_closed);
    hs_set_keep_child_nodes(r->handle, enif_is_identical(argv[1], atom_true) ? 1 : 0);
    return atom_ok;
}

static ERL_NIF_TERM nif_get_keep_child_nodes(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    hs_res *r;
    (void)argc;

    if (!get_res(env, argv[0], &r)) return enif_make_badarg(env);
    if (!r->handle) return err(env, atom_closed);
    return bool_term(hs_get_keep_child_nodes(r->handle));
}

static ERL_NIF_TERM nif_set_allow_data_attributes(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    hs_res *r;
    (void)argc;

    if (!get_res(env, argv[0], &r)) return enif_make_badarg(env);
    if (!r->handle) return err(env, atom_closed);
    hs_set_allow_data_attributes(r->handle, enif_is_identical(argv[1], atom_true) ? 1 : 0);
    return atom_ok;
}

static ERL_NIF_TERM nif_get_allow_data_attributes(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    hs_res *r;
    (void)argc;

    if (!get_res(env, argv[0], &r)) return enif_make_badarg(env);
    if (!r->handle) return err(env, atom_closed);
    return bool_term(hs_get_allow_data_attributes(r->handle));
}

/* ---- allow-lists ----
 *
 * `which` is the ABI selector: 0=tags 1=attributes 2=css_properties
 * 3=schemes 4=classes 5=uri_attributes. The Erlang wrapper (src/
 * htmlsanitizer.erl) maps friendly atoms onto these integers so callers never
 * write a bare number; validating the range here keeps a hand-rolled call
 * from reaching hs_pick_set with nonsense. */

static int get_which(ErlNifEnv *env, ERL_NIF_TERM term, int *out)
{
    int w;
    if (!enif_get_int(env, term, &w)) return 0;
    if (w < 0 || w > 5) return 0;
    *out = w;
    return 1;
}

/* Shared body for allow/3, disallow/3 and is_allowed/3. */
static ERL_NIF_TERM do_list_op(ErlNifEnv *env, const ERL_NIF_TERM argv[],
                               int (*fn)(void *, int, const char *))
{
    hs_res *r;
    int which, rc;
    char *item;

    if (!get_res(env, argv[0], &r)) return enif_make_badarg(env);
    if (!r->handle) return err(env, atom_closed);
    if (!get_which(env, argv[1], &which)) return err(env, atom_badarg);
    item = term_to_cstr(env, argv[2]);
    if (!item) return enif_make_badarg(env);
    rc = fn(r->handle, which, item);
    enif_free(item);
    return bool_term(rc);
}

static ERL_NIF_TERM nif_allow(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    return do_list_op(env, argv, hs_allow);
}

static ERL_NIF_TERM nif_disallow(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    return do_list_op(env, argv, hs_disallow);
}

static ERL_NIF_TERM nif_is_allowed(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc;
    return do_list_op(env, argv, hs_is_allowed);
}

static ERL_NIF_TERM nif_clear(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    hs_res *r;
    int which;
    (void)argc;

    if (!get_res(env, argv[0], &r)) return enif_make_badarg(env);
    if (!r->handle) return err(env, atom_closed);
    if (!get_which(env, argv[1], &which)) return err(env, atom_badarg);
    return bool_term(hs_clear(r->handle, which));
}

static ERL_NIF_TERM nif_count(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    hs_res *r;
    int which;
    (void)argc;

    if (!get_res(env, argv[0], &r)) return enif_make_badarg(env);
    if (!r->handle) return err(env, atom_closed);
    if (!get_which(env, argv[1], &which)) return err(env, atom_badarg);
    return enif_make_int(env, hs_count(r->handle, which));
}

/* items/2 builds the whole list in C rather than exposing item_at/3.
 *
 * The ABI's item_at snapshots the set per call (O(n) each, O(n^2) to walk),
 * and a BEAM caller looping in Erlang would pay a NIF crossing per entry on
 * top. Doing the loop here is one crossing and one pass' worth of allocation.
 * Every returned char* is freed through take_binary as we go. */
static ERL_NIF_TERM nif_items(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    hs_res *r;
    int which, n, i;
    ERL_NIF_TERM list;
    (void)argc;

    if (!get_res(env, argv[0], &r)) return enif_make_badarg(env);
    if (!r->handle) return err(env, atom_closed);
    if (!get_which(env, argv[1], &which)) return err(env, atom_badarg);

    n = hs_count(r->handle, which);
    list = enif_make_list(env, 0);
    /* Build back-to-front so the result comes out in the sanitizer core's own order. */
    for (i = n - 1; i >= 0; i--) {
        ERL_NIF_TERM item = take_binary(env, hs_item_at(r->handle, which, i));
        list = enif_make_list_cell(env, item, list);
    }
    return list;
}

/* ---- introspection ---- */

static ERL_NIF_TERM nif_abi_version(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    (void)argc; (void)argv;
    return enif_make_int(env, hs_abi_version());
}

/* ---- sanitizer core discovery + symbol resolution ----
 *
 * Order, matching every other binding in the monorepo:
 *   1. $HTMLSANITIZER_LIB
 *   2. priv/ next to this NIF (the bundled copy .build.ae stages)
 *   3. the OS loader's own search path
 *
 * We dlopen rather than link so the NIF .so has no DT_NEEDED on the sanitizer core:
 * the BEAM can load this module even when the sanitizer core is missing, and report a
 * clean {error, {load_failed, ...}} instead of dying in the dynamic linker.
 */

#define RESOLVE(var, name)                                     \
    do {                                                       \
        *(void **)(&var) = HS_DLSYM(hs_lib, name);             \
        if (!var) {                                            \
            snprintf(errbuf, errlen, "missing symbol %s", name); \
            return 0;                                          \
        }                                                      \
    } while (0)

static int resolve_all(char *errbuf, size_t errlen)
{
    RESOLVE(hs_new, "aether_hs_embed_new");
    RESOLVE(hs_free, "aether_hs_embed_free");
    RESOLVE(hs_free_string, "aether_hs_embed_free_string");
    RESOLVE(hs_sanitize, "aether_hs_embed_sanitize");
    RESOLVE(hs_sanitize_document, "aether_hs_embed_sanitize_document");
    RESOLVE(hs_set_keep_child_nodes, "aether_hs_embed_set_keep_child_nodes");
    RESOLVE(hs_get_keep_child_nodes, "aether_hs_embed_get_keep_child_nodes");
    RESOLVE(hs_set_allow_data_attributes, "aether_hs_embed_set_allow_data_attributes");
    RESOLVE(hs_get_allow_data_attributes, "aether_hs_embed_get_allow_data_attributes");
    RESOLVE(hs_allow, "aether_hs_embed_allow");
    RESOLVE(hs_disallow, "aether_hs_embed_disallow");
    RESOLVE(hs_is_allowed, "aether_hs_embed_is_allowed");
    RESOLVE(hs_clear, "aether_hs_embed_clear");
    RESOLVE(hs_count, "aether_hs_embed_count");
    RESOLVE(hs_item_at, "aether_hs_embed_item_at");
    RESOLVE(hs_abi_version, "aether_hs_embed_abi_version");
    return 1;
}

/* Where is this NIF's priv/ directory? The load info term carries it (see
 * htmlsanitizer_nif.erl), which is more reliable than guessing from code:priv_dir
 * inside C. */
static int open_engine(ErlNifEnv *env, ERL_NIF_TERM load_info, char *errbuf, size_t errlen)
{
    char path[4096];
    const char *env_path = getenv("HTMLSANITIZER_LIB");

    if (env_path && *env_path) {
        hs_lib = HS_DLOPEN(env_path);
        if (hs_lib) return 1;
    }

    /* load_info is the priv dir as a binary, or the atom 'undefined'. */
    {
        ErlNifBinary bin;
        if (enif_inspect_binary(env, load_info, &bin) && bin.size > 0 &&
            bin.size + 1 + sizeof(HS_LIB_NAME) < sizeof(path)) {
            memcpy(path, bin.data, bin.size);
            path[bin.size] = '\0';
            strcat(path, "/");
            strcat(path, HS_LIB_NAME);
            hs_lib = HS_DLOPEN(path);
            if (hs_lib) return 1;
        }
    }

    /* Let the OS loader try its own search path (LD_LIBRARY_PATH, rpath, …). */
    hs_lib = HS_DLOPEN(HS_LIB_NAME);
    if (hs_lib) return 1;

    snprintf(errbuf, errlen,
             "could not load %s. Set HTMLSANITIZER_LIB to its absolute path.",
             HS_LIB_NAME);
    return 0;
}

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info)
{
    char errbuf[512];
    ErlNifResourceFlags flags = (ErlNifResourceFlags)(ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER);
    (void)priv_data;

    errbuf[0] = '\0';

    HS_RES_TYPE = enif_open_resource_type(env, NULL, "htmlsanitizer",
                                          hs_res_dtor, flags, NULL);
    if (!HS_RES_TYPE) {
        return 1;
    }

    if (!open_engine(env, load_info, errbuf, sizeof(errbuf))) {
        enif_fprintf(stderr, "htmlsanitizer_nif: %s\n", errbuf);
        return 2;
    }
    if (!resolve_all(errbuf, sizeof(errbuf))) {
        enif_fprintf(stderr, "htmlsanitizer_nif: %s\n", errbuf);
        return 3;
    }

    atom_ok           = enif_make_atom(env, "ok");
    atom_error        = enif_make_atom(env, "error");
    atom_true         = enif_make_atom(env, "true");
    atom_false        = enif_make_atom(env, "false");
    atom_closed       = enif_make_atom(env, "closed");
    atom_badarg       = enif_make_atom(env, "badarg");
    atom_alloc_failed = enif_make_atom(env, "alloc_failed");

    return 0;
}

/* An upgrade re-runs load's work in the new instance. */
static int upgrade(ErlNifEnv *env, void **priv_data, void **old_priv_data,
                   ERL_NIF_TERM load_info)
{
    (void)old_priv_data;
    return load(env, priv_data, load_info);
}

static ErlNifFunc nif_funcs[] = {
    {"new",              0, nif_new,                       0},
    {"close",            1, nif_close,                     0},
    {"is_closed",        1, nif_is_closed,                 0},
    /* Parsing arbitrary HTML can exceed the 1ms a normal NIF may occupy a
     * scheduler for, so these two run on a dirty CPU scheduler. */
    {"sanitize",         3, nif_sanitize,                  ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"sanitize_document",3, nif_sanitize_document,         ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"set_keep_child_nodes",      2, nif_set_keep_child_nodes,      0},
    {"get_keep_child_nodes",      1, nif_get_keep_child_nodes,      0},
    {"set_allow_data_attributes", 2, nif_set_allow_data_attributes, 0},
    {"get_allow_data_attributes", 1, nif_get_allow_data_attributes, 0},
    {"allow",            3, nif_allow,                     0},
    {"disallow",         3, nif_disallow,                  0},
    {"is_allowed",       3, nif_is_allowed,                0},
    {"clear",            2, nif_clear,                     0},
    {"count",            2, nif_count,                     0},
    {"items",            2, nif_items,                     0},
    {"abi_version",      0, nif_abi_version,               0}
};

ERL_NIF_INIT(htmlsanitizer_nif, nif_funcs, load, NULL, upgrade, NULL)
