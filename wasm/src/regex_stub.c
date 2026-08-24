/* The sanitizer's only regex use is the never-wired
 * disallow_css_property_value_regex field, which is always null. Stubbing
 * these keeps PCRE2 (and its whole port build) out of the WASM bundle. */
#include <stddef.h>
void* aether_regex_new(const char* p, int f) { (void)p; (void)f; return NULL; }
int aether_regex_matches(void* r, const char* s) { (void)r; (void)s; return 0; }
void aether_regex_free(void* r) { (void)r; }
