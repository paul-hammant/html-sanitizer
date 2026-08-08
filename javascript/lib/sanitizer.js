'use strict';
/**
 * Idiomatic JavaScript surface over the HtmlSanitizer engine.
 *
 * Carries no sanitizer logic — see the monorepo's one rule. Every method here
 * marshals to an `aether_hs_embed_*` call in `native.js`.
 */

const native = require('./native');
const koffi = native.koffi;

const {
  TAGS, ATTRIBUTES, CSS_PROPERTIES, SCHEMES, CLASSES, URI_ATTRIBUTES,
} = native;

// libc's strdup, for the one hook that must hand the engine a malloc'd
// string it will then own (on_filter_url). Loaded lazily so a host that
// never installs that hook never needs libc resolved.
let _strdup = null;
function strdup(s) {
  if (_strdup === null) {
    const libcName = {
      darwin: 'libc.dylib',
      win32: 'msvcrt.dll',
    }[process.platform] || 'libc.so.6';
    const libc = koffi.load(libcName);
    _strdup = libc.func('void *strdup(const char *s)');
  }
  return _strdup(s === null || s === undefined ? '' : String(s));
}

/**
 * A DOM attribute, borrowed for the duration of a callback.
 *
 * Do not retain one past the callback that gave it to you — the DOM is freed
 * when sanitize() returns.
 */
class Attribute {
  constructor(api, ptr) {
    this._api = api;
    this._ptr = ptr;
  }

  get name() {
    return native.takeString(this._api, this._api.attrName(this._ptr));
  }

  get value() {
    return native.takeString(this._api, this._api.attrValue(this._ptr));
  }

  set value(v) {
    this._api.attrSetValue(this._ptr, v === null || v === undefined ? '' : String(v));
  }

  toString() {
    return `Attribute(${this.name}=${JSON.stringify(this.value)})`;
  }
}

/** A DOM node, borrowed for the duration of a callback. */
class Node {
  constructor(api, ptr) {
    this._api = api;
    this._ptr = ptr;
  }

  /** 1=Document, 2=Element, 3=Text, 4=Comment. */
  get kind() {
    return this._api.nodeKind(this._ptr);
  }

  get name() {
    return native.takeString(this._api, this._api.nodeName(this._ptr));
  }

  get value() {
    return native.takeString(this._api, this._api.nodeValue(this._ptr));
  }

  get parent() {
    const p = this._api.nodeParent(this._ptr);
    return p ? new Node(this._api, p) : null;
  }

  get children() {
    const n = this._api.nodeChildCount(this._ptr);
    const out = [];
    for (let i = 0; i < n; i++) {
      out.push(new Node(this._api, this._api.nodeChildAt(this._ptr, i)));
    }
    return out;
  }

  get attributes() {
    const n = this._api.nodeAttrCount(this._ptr);
    const out = [];
    for (let i = 0; i < n; i++) {
      out.push(new Attribute(this._api, this._api.nodeAttrAt(this._ptr, i)));
    }
    return out;
  }

  toString() {
    return `Node(kind=${this.kind}, name=${JSON.stringify(this.name)})`;
  }
}

/** Set-like view over one of the engine's six policy lists. */
class AllowList {
  constructor(owner, which) {
    this._owner = owner;
    this._which = which;
  }

  add(item) {
    this._owner._api.allow(this._owner._h, this._which, String(item));
    return this;
  }

  update(items) {
    for (const i of items) this.add(i);
    return this;
  }

  delete(item) {
    this._owner._api.disallow(this._owner._h, this._which, String(item));
    return this;
  }

  clear() {
    this._owner._api.clear(this._owner._h, this._which);
    return this;
  }

  has(item) {
    return this._owner._api.isAllowed(
      this._owner._h, this._which, String(item)) !== 0;
  }

  get size() {
    return this._owner._api.count(this._owner._h, this._which);
  }

  *[Symbol.iterator]() {
    const { _api: api, _h: h } = this._owner;
    const n = this.size;
    for (let i = 0; i < n; i++) {
      yield native.takeString(api, api.itemAt(h, this._which, i));
    }
  }

  toArray() {
    return [...this];
  }

  toString() {
    return `{${this.toArray().sort().map((x) => JSON.stringify(x)).join(', ')}}`;
  }
}

/**
 * Cleans HTML of constructs that can lead to XSS.
 *
 *     const s = new HtmlSanitizer();
 *     s.allowedTags.add('my-widget');
 *     const clean = s.sanitize('<div onclick="evil()">hi</div>');
 *     s.close();
 *
 * Call close() to release the native handle. JavaScript has no deterministic
 * destructor, so a long-lived process should close explicitly; a FinalizationRegistry
 * backstop frees handles that are dropped without one.
 */
class HtmlSanitizer {
  constructor(options = {}) {
    const nativeLib = typeof options === 'string' ? options : options.nativeLib;
    this._api = native.load(nativeLib);
    this._h = this._api.new();
    if (!this._h) throw new Error('failed to create the native sanitizer');

    // Registered koffi callbacks must be kept alive for as long as the engine
    // can call them — an unregistered trampoline would crash the process.
    // We also unregister them on close() so the slots are reclaimed.
    this._keepalive = [];

    this.allowedTags = new AllowList(this, TAGS);
    this.allowedAttributes = new AllowList(this, ATTRIBUTES);
    this.allowedCssProperties = new AllowList(this, CSS_PROPERTIES);
    this.allowedSchemes = new AllowList(this, SCHEMES);
    this.allowedClasses = new AllowList(this, CLASSES);
    this.uriAttributes = new AllowList(this, URI_ATTRIBUTES);

    HtmlSanitizer._registry.register(this, { api: this._api, h: this._h }, this);
  }

  // ---- lifecycle ----

  close() {
    if (this._h) {
      HtmlSanitizer._registry.unregister(this);
      this._api.free(this._h);
      this._h = null;
      for (const cb of this._keepalive) {
        try {
          koffi.unregister(cb);
        } catch {
          /* already gone — nothing to reclaim */
        }
      }
      this._keepalive = [];
    }
  }

  /** `using`/`Symbol.dispose` support, when the runtime offers it. */
  [Symbol.dispose || Symbol.for('nodejs.dispose')]() {
    this.close();
  }

  _check() {
    if (!this._h) throw new Error('sanitizer is closed');
  }

  // ---- the main entry point ----

  sanitize(html, baseUrl = '') {
    this._check();
    return native.takeString(
      this._api, this._api.sanitize(this._h, html || '', baseUrl || ''));
  }

  sanitizeDocument(html, baseUrl = '') {
    this._check();
    return native.takeString(
      this._api, this._api.sanitizeDocument(this._h, html || '', baseUrl || ''));
  }

  // ---- flags ----

  get keepChildNodes() {
    return this._api.getKeepChildNodes(this._h) !== 0;
  }

  set keepChildNodes(on) {
    this._api.setKeepChildNodes(this._h, on ? 1 : 0);
  }

  get allowDataAttributes() {
    return this._api.getAllowDataAttributes(this._h) !== 0;
  }

  set allowDataAttributes(on) {
    this._api.setAllowDataAttributes(this._h, on ? 1 : 0);
  }

  get abiVersion() {
    return this._api.abiVersion();
  }

  // ---- callbacks ----
  //
  // Each `on*` takes a function and returns `this`, so they chain. Passing
  // null clears the hook. For the `removing*` family, returning true from
  // your handler CANCELS the removal (keeps the node); returning false or
  // undefined lets it proceed.

  _install(register, proto, impl, handler) {
    this._check();
    if (handler === null || handler === undefined) {
      register(this._h, null, null);
      return this;
    }
    const cb = koffi.register(impl, koffi.pointer(proto));
    this._keepalive.push(cb);
    register(this._h, cb, null);
    return this;
  }

  onRemovingTag(handler) {
    return this._install(
      this._api.onRemovingTag, native.CB_REMOVING_TAG,
      (_ud, node, reason) => (handler(new Node(this._api, node), reason) ? 1 : 0),
      handler);
  }

  onRemovingAttribute(handler) {
    return this._install(
      this._api.onRemovingAttribute, native.CB_REMOVING_ATTRIBUTE,
      (_ud, elem, attr, reason) => (handler(
        new Node(this._api, elem), new Attribute(this._api, attr), reason) ? 1 : 0),
      handler);
  }

  onRemovingStyle(handler) {
    return this._install(
      this._api.onRemovingStyle, native.CB_REMOVING_STYLE,
      (_ud, elem, name, value, reason) => (handler(
        new Node(this._api, elem), native.readString(name),
        native.readString(value), reason) ? 1 : 0),
      handler);
  }

  onRemovingComment(handler) {
    return this._install(
      this._api.onRemovingComment, native.CB_REMOVING_COMMENT,
      (_ud, node) => (handler(new Node(this._api, node)) ? 1 : 0),
      handler);
  }

  onPostProcessNode(handler) {
    return this._install(
      this._api.onPostProcessNode, native.CB_POST_PROCESS,
      (_ud, node) => { handler(new Node(this._api, node)); },
      handler);
  }

  onPostProcessDom(handler) {
    return this._install(
      this._api.onPostProcessDom, native.CB_POST_PROCESS,
      (_ud, doc) => { handler(new Node(this._api, doc)); },
      handler);
  }

  /**
   * handler(node, rawUrl, resolvedUrl) -> string
   *
   * Return the URL to use ('' drops the attribute). The returned string is
   * copied into a malloc'd C buffer the engine takes ownership of.
   */
  onFilterUrl(handler) {
    return this._install(
      this._api.onFilterUrl, native.CB_FILTER_URL,
      (_ud, elem, raw, resolved) => strdup(handler(
        new Node(this._api, elem), native.readString(raw), native.readString(resolved))),
      handler);
  }
}

// Backstop for handles dropped without close(). Not a substitute for calling
// close() — GC timing is not a resource-management strategy — but it keeps a
// forgotten sanitizer from leaking the engine's whole DOM arena forever.
HtmlSanitizer._registry = new FinalizationRegistry(({ api, h }) => {
  if (h) api.free(h);
});

module.exports = { HtmlSanitizer, Node, Attribute, AllowList };
