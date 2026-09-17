/* core/_embed_support.c — the irreducible C under the HtmlSanitizer C ABI.
 *
 * The sanitizer core is pure Aether (core/htmlsanitizer.ae). This file
 * carries only the two things Aether's stdlib cannot express, both of them
 * FFI plumbing rather than sanitizer logic. (A third — reading a std.set
 * items() snapshot — was here until ae 0.576 added set.items_size /
 * items_get; embed.ae now calls those directly.)
 *
 *   1. hs_raw_dup / hs_raw_free — the caller-owned-string bridge. Every
 *      `char*` the ABI returns is a plain malloc'd, NUL-terminated copy that
 *      the host frees with aether_htmlsanitizer_embed_free_string(). Aether's
 *      std.mem is access-only (no allocation), and the bindings free returned
 *      pointers with C free(), so this cannot be Aether.
 *
 *   2. The CALLBACK TRAMPOLINES — hs_embed_cb_*(). The sanitizer core's hook slots
 *      (HtmlSanitizer.on_removing_tag, .on_filter_url, …) hold heap-boxed
 *      Aether closures, and the sanitizer core invokes them via `call(cb, ...)`, which
 *      lowers to `fn(env, args...)`. A foreign function pointer is NOT that
 *      shape, so a binding cannot drop its own callback into the slot. These
 *      builders malloc a box in the SAME layout codegen uses,
 *
 *          typedef struct { void (*fn)(void); void* env;
 *                           unsigned long long tag; } _AeClosureBox;
 *
 *      (the `tag` is mandatory as of aether #1439 — see HS_CLOSURE_TAG below)
 *
 *      set .fn to a trampoline of the right arity, and hide the host's
 *      function pointer (plus an opaque user_data) in .env. When the sanitizer core
 *      calls the slot, the trampoline unpacks env and forwards to the host.
 *      That is what gives all 21 bindings real hook support over one ABI.
 *
 * Ownership of the boxes: the sanitizer core's `free()` heap.free()s each non-null
 * hook slot, which releases the box; the HsCb env is freed by embed.ae
 * calling hs_embed_cb_free_env() before it drops the sanitizer. See the
 * "callbacks" section of core/embed.ae.
 *
 * Linked into the .so via `--extra` from core/.build.ae only.
 */
#include <stdlib.h>
#include <string.h>

/* Aether's string ABI (std/string/aether_string.h, docs/aether-string-abi.md).
 *
 * An Aether `string` crossing a `const char*` slot is NOT necessarily a C
 * string: builtins hand back a refcounted `AetherString*` whose first bytes
 * are a magic header, not content. aether_string_data() accepts either shape
 * and returns the real byte pointer; string_new() builds an AetherString the
 * sanitizer core can consume. Every string in or out of a callback goes through
 * these — reading one raw is how you get mojibake. */
const char* aether_string_data(const void* s);
void* string_new(const char* cstr);

/* ---- 1. caller-owned string bridge ---- */

char* hs_raw_dup(const char* s) {
    if (!s) s = "";
    size_t n = strlen(s) + 1;
    char* d = (char*)malloc(n);
    if (d) memcpy(d, s, n);
    return d;
}

void hs_raw_free(char* s) {
    free(s);
}

/* ---- 2. callback trampolines ---- */

/* Mirrors codegen's _AeClosureBox. This TU need not see the generated
 * typedef; the layout is the contract (see the aether_stringseq.h "Closure
 * ABI" note upstream). The `tag` third field is REQUIRED as of
 * aether #1439: _aether_unbox_closure() now validates it and panics with
 * "unbox_closure() on a value that was never boxed" otherwise — which is
 * exactly what a bare two-word box looks like to it. The fn/env prefix is
 * deliberately unchanged (std/collections and std/worker mirror that layout,
 * so the tag has to go last, never first). */
#define HS_CLOSURE_TAG 0xAEC105EDB0CEDULL
typedef struct { void (*fn)(void); void* env; unsigned long long tag; } HsClosure;

/* What we smuggle through .env: the host's function pointer plus an opaque
 * user_data the host uses to find its own instance/handler. */
typedef struct { void* host_fn; void* user_data; } HsCb;

/* Trampolines. Each matches ONE hook signature in core/htmlsanitizer.ae, and
 * each receives the env as its implicit first argument. The host-side
 * signature is the same argument list with `void* user_data` prepended. */

/* on_removing_tag(node: ptr, reason: int) -> int
 * Sanitizer core call site: `call(cb, node, REASON_NOT_ALLOWED_TAG)`. Non-zero
 * return CANCELS the removal (keeps the tag). */
static int hs_tramp_ptr_int_ret_int(void* env, void* elem, int reason) {
    HsCb* cb = (HsCb*)env;
    if (!cb || !cb->host_fn) return 0;
    return ((int (*)(void*, void*, int))cb->host_fn)(cb->user_data, elem, reason);
}

/* on_removing_attribute(elem: ptr, attr_ptr: ptr, reason: int) -> int
 * Sanitizer core call site: `call(cb, elem, attr_ptr, reason)`. `attr_ptr` is a
 * *DomAttr. Non-zero return cancels the removal. */
static int hs_tramp_ptr_ptr_int_ret_int(void* env, void* a, void* b, int reason) {
    HsCb* cb = (HsCb*)env;
    if (!cb || !cb->host_fn) return 0;
    return ((int (*)(void*, void*, void*, int))cb->host_fn)(cb->user_data, a, b, reason);
}

/* on_removing_style(elem: ptr, prop_name: string, prop_val: string, reason: int) -> int
 * Sanitizer core call site: `call(cb, elem, prop_name, prop_val, reason)` — FOUR
 * arguments, unlike the tag/attribute hooks. Non-zero cancels the removal. */
static int hs_tramp_style(void* env, void* elem,
                          const char* prop_name, const char* prop_val, int reason) {
    HsCb* cb = (HsCb*)env;
    if (!cb || !cb->host_fn) return 0;
    return ((int (*)(void*, void*, const char*, const char*, int))
            cb->host_fn)(cb->user_data, elem,
                         aether_string_data(prop_name),
                         aether_string_data(prop_val), reason);
}

/* on_removing_comment(comment: ptr) -> int */
static int hs_tramp_ptr_ret_int(void* env, void* node) {
    HsCb* cb = (HsCb*)env;
    if (!cb || !cb->host_fn) return 0;
    return ((int (*)(void*, void*))cb->host_fn)(cb->user_data, node);
}

/* on_post_process_node(node: ptr) / on_post_process_dom(doc: ptr)
 * Codegen emits the discarded-result call as `int(*)(void*, void*)`, so the
 * trampoline returns int; the host callback returns void and we report 0. */
static int hs_tramp_ptr_ret_void(void* env, void* node) {
    HsCb* cb = (HsCb*)env;
    if (!cb || !cb->host_fn) return 0;
    ((void (*)(void*, void*))cb->host_fn)(cb->user_data, node);
    return 0;
}

/* on_filter_url(elem: ptr, raw: string, resolved: string) -> string
 *
 * String ownership across this hop: the host returns a malloc'd C string
 * (typically via aether_htmlsanitizer_embed_dup, or its own strdup). The
 * sanitizer core takes the returned pointer as an Aether `string`. We must NOT free
 * it here — the sanitizer core owns it downstream. A host returning NULL means "no
 * rewrite", which we translate to the resolved URL unchanged. */
static const char* hs_tramp_filter_url(void* env, void* elem,
                                       const char* raw, const char* resolved) {
    HsCb* cb = (HsCb*)env;
    if (!cb || !cb->host_fn) return resolved;
    /* In: unwrap the sanitizer core's AetherString* into plain C strings the host can
     * read. Out: the host returns a plain malloc'd C string, but the sanitizer core
     * assigns the result into an Aether `string` slot — so wrap it back into
     * an AetherString. The host's buffer is copied by string_new and freed
     * here, keeping the "host returns malloc'd, we take it" contract. */
    const char* c_raw = aether_string_data(raw);
    const char* c_resolved = aether_string_data(resolved);
    char* out = ((char* (*)(void*, void*, const char*, const char*))
                 cb->host_fn)(cb->user_data, elem, c_raw, c_resolved);
    if (!out) return resolved;
    /* An unchanged reply means "no rewrite" — hand the original back so we
     * neither copy nor free a pointer the host does not own. */
    if (out == c_resolved || out == c_raw) return resolved;
    void* wrapped = string_new(out);
    free(out);
    return (const char*)wrapped;
}

/* Box builders. One per trampoline shape; embed.ae exposes a `kind`-switched
 * wrapper so the ABI stays small. Returns a malloc'd HsClosure the sanitizer core's
 * heap.free() will release; the HsCb env is freed via hs_embed_cb_free_env. */
static void* hs_box(void (*fn)(void), void* host_fn, void* user_data) {
    HsCb* env = (HsCb*)malloc(sizeof(HsCb));
    if (!env) return NULL;
    env->host_fn = host_fn;
    env->user_data = user_data;
    HsClosure* box = (HsClosure*)malloc(sizeof(HsClosure));
    if (!box) { free(env); return NULL; }
    box->fn = fn;
    box->env = env;
    box->tag = HS_CLOSURE_TAG;
    return box;
}

/* kind selects the trampoline arity/shape. These constants are ABI — they
 * are mirrored in every binding, so append only, never renumber:
 *   0 = (elem, reason) -> int              on_removing_tag
 *   1 = (elem, attr, reason) -> int        on_removing_attribute
 *   2 = (node) -> int                      on_removing_comment
 *   3 = (node) -> void                     on_post_process_node, _dom
 *   4 = (elem, raw, resolved) -> str       on_filter_url
 *   5 = (elem, name, val, reason) -> int   on_removing_style
 * Returns NULL for an unknown kind or a NULL host_fn (the caller then leaves
 * the hook slot unset, which is the "no callback" state). */
void* hs_embed_cb_box(int kind, void* host_fn, void* user_data) {
    if (!host_fn) return NULL;
    switch (kind) {
        case 0: return hs_box((void (*)(void))hs_tramp_ptr_int_ret_int, host_fn, user_data);
        case 1: return hs_box((void (*)(void))hs_tramp_ptr_ptr_int_ret_int, host_fn, user_data);
        case 2: return hs_box((void (*)(void))hs_tramp_ptr_ret_int, host_fn, user_data);
        case 3: return hs_box((void (*)(void))hs_tramp_ptr_ret_void, host_fn, user_data);
        case 4: return hs_box((void (*)(void))hs_tramp_filter_url, host_fn, user_data);
        case 5: return hs_box((void (*)(void))hs_tramp_style, host_fn, user_data);
        default: return NULL;
    }
}

/* Free the env a box carries, WITHOUT freeing the box itself — the sanitizer core's
 * heap.free() on the hook slot does that. Call this immediately before
 * dropping the sanitizer (embed.ae's free path). NULL-safe. */
void hs_embed_cb_free_env(void* boxp) {
    HsClosure* box = (HsClosure*)boxp;
    if (!box) return;
    free(box->env);
    box->env = NULL;
}

/* Free a box AND its env — for replacing or clearing a hook.
 *
 * The distinction matters and was a real leak. hs_embed_cb_free_env() alone
 * releases the env but leaves the two-word box, which is correct ONLY on the
 * teardown path, where the sanitizer core's own free() heap.free()s each hook slot
 * right after. When a hook is REPLACED or CLEARED, nothing else ever sees the
 * outgoing pointer, so the box leaked — which made defensively clearing hooks
 * before free strictly worse than leaving them installed (16 bytes per
 * clear/replace). embed.ae's swap_hook now calls this instead. */
void hs_embed_cb_free_box(void* boxp) {
    HsClosure* box = (HsClosure*)boxp;
    if (!box) return;
    free(box->env);
    free(box);
}
