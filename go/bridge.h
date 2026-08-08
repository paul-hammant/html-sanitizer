/* bridge.h — C-side declarations for the Go callback trampolines.
 *
 * cgo forbids passing a Go pointer to C, and it cannot take the address of a
 * Go func to hand the engine a raw function pointer. The standard pattern is
 * therefore: register these plain C functions with the engine, have each one
 * call back into an //export-ed Go function, and smuggle the identity of the
 * owning Go object through the ABI's opaque `user_data` as a runtime/cgo
 * Handle (a uintptr, never a pointer into the Go heap).
 *
 * Signatures mirror core/embed.ae exactly: user_data first, C `int` returns.
 */
#ifndef HTMLSANITIZER_BRIDGE_H
#define HTMLSANITIZER_BRIDGE_H

int   hsgo_removing_tag(void* ud, void* node, int reason);
int   hsgo_removing_attribute(void* ud, void* elem, void* attr, int reason);
int   hsgo_removing_style(void* ud, void* elem, const char* name,
                          const char* value, int reason);
int   hsgo_removing_comment(void* ud, void* node);
void  hsgo_post_process_node(void* ud, void* node);
void  hsgo_post_process_dom(void* ud, void* node);
char* hsgo_filter_url(void* ud, void* elem, const char* raw,
                      const char* resolved);

#endif /* HTMLSANITIZER_BRIDGE_H */
