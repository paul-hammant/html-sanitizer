'use strict';
/**
 * koffi bindings for the HtmlSanitizer core (libhtmlsanitizer.so).
 *
 * This module is the ONLY place in the JavaScript binding that knows about
 * the C ABI. Everything above it (`sanitizer.js`) is idiomatic JavaScript
 * over these symbols. No sanitizer logic lives here or anywhere else in this
 * package — the sanitizer core is `core/htmlsanitizer.ae`, shared by every binding.
 *
 * Library resolution, in order:
 *   1. an explicit path passed to `load(path)` / `new HtmlSanitizer({ nativeLib })`
 *   2. $HTMLSANITIZER_LIB          (what the in-tree .tests.ae leaves set)
 *   3. native/ bundled next to this package (what an installed tarball ships)
 *   4. the OS loader's own search path
 */

const koffi = require('koffi');
const path = require('path');

const LIB_NAME = {
  darwin: 'libhtmlsanitizer.dylib',
  win32: 'htmlsanitizer.dll',
}[process.platform] || 'libhtmlsanitizer.so';

// ---- allow-list selectors (ABI constants — append only, never renumber) ----
const TAGS = 0;
const ATTRIBUTES = 1;
const CSS_PROPERTIES = 2;
const SCHEMES = 3;
const CLASSES = 4;
const URI_ATTRIBUTES = 5;

// ---- removal reasons, as passed to the callbacks ----
const REASON_NOT_ALLOWED_TAG = 0;
const REASON_NOT_ALLOWED_ATTRIBUTE = 1;
const REASON_NOT_ALLOWED_STYLE = 2;
const REASON_NOT_ALLOWED_URL_VALUE = 3;
const REASON_NOT_ALLOWED_VALUE = 4;
const REASON_NOT_ALLOWED_CSS_CLASS = 5;
const REASON_CLASS_ATTRIBUTE_EMPTY = 6;
const REASON_STYLE_ATTRIBUTE_EMPTY = 7;

// ---- node kinds ----
const NODE_DOCUMENT = 1;
const NODE_ELEMENT = 2;
const NODE_TEXT = 3;
const NODE_COMMENT = 4;

// ---- callback prototypes ----
//
// Each takes an opaque user_data FIRST; the sanitizer core's trampoline supplies it.
// The `removing_*` family returns int — NON-ZERO CANCELS the removal.
//
// `const char *` PARAMETERS arrive already decoded as JS strings (koffi knows
// the type from the prototype). Pointer parameters typed `void *` arrive as
// BigInt addresses, which is what the DOM accessors want anyway.
//
// Note the return type of every string-returning ABI call is `void *`, not
// `const char *`: koffi would otherwise decode-and-forget the pointer and we
// could never hand it back to aether_hs_embed_free_string. Every one of those
// is caller-owned, and leaking it is the single easiest mistake in a binding.
const CB_REMOVING_TAG =
  koffi.proto('int CbRemovingTag(void *ud, void *node, int reason)');
const CB_REMOVING_ATTRIBUTE =
  koffi.proto('int CbRemovingAttribute(void *ud, void *elem, void *attr, int reason)');
const CB_REMOVING_STYLE =
  koffi.proto('int CbRemovingStyle(void *ud, void *elem, const char *name, const char *value, int reason)');
const CB_REMOVING_COMMENT =
  koffi.proto('int CbRemovingComment(void *ud, void *node)');
const CB_POST_PROCESS =
  koffi.proto('void CbPostProcess(void *ud, void *node)');
// filter_url hands back a malloc'd C string the sanitizer core takes ownership of,
// so it is declared `void *` and we allocate it ourselves (see sanitizer.js).
const CB_FILTER_URL =
  koffi.proto('void *CbFilterUrl(void *ud, void *elem, const char *raw, const char *resolved)');

let cached = null;

function* candidates(explicit) {
  if (explicit) {
    yield explicit;
    return;
  }
  const env = process.env.HTMLSANITIZER_LIB;
  if (env) yield env;
  yield path.join(__dirname, '..', 'native', LIB_NAME);
  yield LIB_NAME;
}

/**
 * Load the sanitizer core .so, caching it process-wide. Returns the symbol table.
 */
function load(explicit) {
  if (cached !== null && !explicit) return cached;

  let lib = null;
  let last = null;
  for (const cand of candidates(explicit)) {
    try {
      lib = koffi.load(cand);
      break;
    } catch (err) {
      last = err;
    }
  }
  if (lib === null) {
    throw new Error(
      `could not load the HtmlSanitizer core (${LIB_NAME}). Set ` +
      'HTMLSANITIZER_LIB to its absolute path, or install a package that ' +
      `bundles it. Last error: ${last && last.message}`);
  }

  const api = declare(lib);
  if (!explicit) cached = api;
  return api;
}

/**
 * Bind every exported symbol. Signature shapes come straight from
 * core/embed.ae; the mangled `aether_` prefix is what `--emit=lib` produces.
 */
function declare(lib) {
  const f = (sig) => lib.func(sig);
  return {
    _lib: lib,

    // ---- lifecycle ----
    new: f('void *aether_hs_embed_new()'),
    free: f('void aether_hs_embed_free(void *h)'),
    freeString: f('void aether_hs_embed_free_string(void *s)'),

    // ---- sanitize ----
    sanitize: f('void *aether_hs_embed_sanitize(void *h, const char *html, const char *base)'),
    sanitizeDocument: f('void *aether_hs_embed_sanitize_document(void *h, const char *html, const char *base)'),

    // ---- flags ----
    setKeepChildNodes: f('void aether_hs_embed_set_keep_child_nodes(void *h, int on)'),
    getKeepChildNodes: f('int aether_hs_embed_get_keep_child_nodes(void *h)'),
    setAllowDataAttributes: f('void aether_hs_embed_set_allow_data_attributes(void *h, int on)'),
    getAllowDataAttributes: f('int aether_hs_embed_get_allow_data_attributes(void *h)'),

    // ---- allow-lists (the `which` selector is an ABI constant) ----
    allow: f('int aether_hs_embed_allow(void *h, int which, const char *item)'),
    disallow: f('int aether_hs_embed_disallow(void *h, int which, const char *item)'),
    isAllowed: f('int aether_hs_embed_is_allowed(void *h, int which, const char *item)'),
    clear: f('int aether_hs_embed_clear(void *h, int which)'),
    count: f('int aether_hs_embed_count(void *h, int which)'),
    itemAt: f('void *aether_hs_embed_item_at(void *h, int which, int index)'),

    // ---- version ----
    abiVersion: f('int aether_hs_embed_abi_version()'),

    // ---- hooks ----
    onRemovingTag: f('void aether_hs_embed_on_removing_tag(void *h, void *fn, void *ud)'),
    onRemovingAttribute: f('void aether_hs_embed_on_removing_attribute(void *h, void *fn, void *ud)'),
    onRemovingStyle: f('void aether_hs_embed_on_removing_style(void *h, void *fn, void *ud)'),
    onRemovingComment: f('void aether_hs_embed_on_removing_comment(void *h, void *fn, void *ud)'),
    onPostProcessNode: f('void aether_hs_embed_on_post_process_node(void *h, void *fn, void *ud)'),
    onPostProcessDom: f('void aether_hs_embed_on_post_process_dom(void *h, void *fn, void *ud)'),
    onFilterUrl: f('void aether_hs_embed_on_filter_url(void *h, void *fn, void *ud)'),

    // ---- DOM accessors (borrowed pointers, valid only inside a callback) ----
    nodeKind: f('int aether_hs_embed_node_kind(void *n)'),
    nodeName: f('void *aether_hs_embed_node_name(void *n)'),
    nodeValue: f('void *aether_hs_embed_node_value(void *n)'),
    nodeChildCount: f('int aether_hs_embed_node_child_count(void *n)'),
    nodeChildAt: f('void *aether_hs_embed_node_child_at(void *n, int index)'),
    nodeParent: f('void *aether_hs_embed_node_parent(void *n)'),
    nodeAttrCount: f('int aether_hs_embed_node_attr_count(void *n)'),
    nodeAttrAt: f('void *aether_hs_embed_node_attr_at(void *n, int index)'),
    attrName: f('void *aether_hs_embed_attr_name(void *a)'),
    attrValue: f('void *aether_hs_embed_attr_value(void *a)'),
    attrSetValue: f('void aether_hs_embed_attr_set_value(void *a, const char *value)'),
  };
}

/**
 * Copy an ABI-returned string out and free it through the ABI.
 *
 * Every char* the sanitizer core returns is caller-owned; leaking it is the single
 * easiest mistake to make in any of these bindings.
 *
 * Koffi 3 represents pointers as BigInt, and a null pointer as `null` — so
 * the falsy check covers both `null` and `0n`.
 */
function takeString(api, ptr) {
  if (!ptr) return '';
  try {
    return koffi.decode.string(ptr);
  } finally {
    api.freeString(ptr);
  }
}

/**
 * Read a borrowed `const char *` a callback was handed. NOT owned by us —
 * the sanitizer core keeps it, so there is nothing to free. Koffi decodes typed
 * `const char *` callback parameters for us, so this is usually a no-op;
 * it exists so the call sites do not have to care.
 */
function readString(ptr) {
  if (!ptr) return '';
  if (typeof ptr === 'string') return ptr;
  return koffi.decode.string(ptr);
}

module.exports = {
  load,
  takeString,
  readString,
  koffi,
  LIB_NAME,
  TAGS, ATTRIBUTES, CSS_PROPERTIES, SCHEMES, CLASSES, URI_ATTRIBUTES,
  NODE_DOCUMENT, NODE_ELEMENT, NODE_TEXT, NODE_COMMENT,
  REASON_NOT_ALLOWED_TAG, REASON_NOT_ALLOWED_ATTRIBUTE,
  REASON_NOT_ALLOWED_STYLE, REASON_NOT_ALLOWED_URL_VALUE,
  REASON_NOT_ALLOWED_VALUE, REASON_NOT_ALLOWED_CSS_CLASS,
  REASON_CLASS_ATTRIBUTE_EMPTY, REASON_STYLE_ATTRIBUTE_EMPTY,
  CB_REMOVING_TAG, CB_REMOVING_ATTRIBUTE, CB_REMOVING_STYLE,
  CB_REMOVING_COMMENT, CB_POST_PROCESS, CB_FILTER_URL,
};
