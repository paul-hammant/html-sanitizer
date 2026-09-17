// Idiomatic JS surface over the HtmlSanitizer WASM module.
//
// Carries no sanitizer logic — the same one-core rule as every other
// binding. Everything here marshals to an `aether_hs_embed_*` call inside
// the wasm instance.
//
//     import { HtmlSanitizer } from './htmlsanitizer.mjs';
//
//     const s = await HtmlSanitizer.create();
//     el.innerHTML = s.sanitize(untrustedHtml);
//
// Why this and not DOMPurify: it is the SAME sanitizer core as the server-side
// bindings, so what your Python/Java/Go backend strips is exactly what the
// browser strips. No two-implementations-two-holes problem.

import createModule from './htmlsanitizer.js';

// Allow-list selectors (ABI constants — mirror of docs/abi.md).
export const TAGS = 0;
export const ATTRIBUTES = 1;
export const CSS_PROPERTIES = 2;
export const SCHEMES = 3;
export const CLASSES = 4;
export const URI_ATTRIBUTES = 5;

let modulePromise = null;

/** Set-like view over one of the sanitizer core's six policy lists. */
class AllowList {
  #owner; #which;
  constructor(owner, which) { this.#owner = owner; this.#which = which; }

  add(item) {
    this.#owner._withCString(item, (p) =>
      this.#owner._m._aether_hs_embed_allow(this.#owner._h, this.#which, p));
    return this;
  }

  delete(item) {
    this.#owner._withCString(item, (p) =>
      this.#owner._m._aether_hs_embed_disallow(this.#owner._h, this.#which, p));
    return this;
  }

  has(item) {
    return !!this.#owner._withCString(item, (p) =>
      this.#owner._m._aether_hs_embed_is_allowed(this.#owner._h, this.#which, p));
  }

  clear() {
    this.#owner._m._aether_hs_embed_clear(this.#owner._h, this.#which);
    return this;
  }

  get size() {
    return this.#owner._m._aether_hs_embed_count(this.#owner._h, this.#which);
  }

  *[Symbol.iterator]() {
    const { _m: m, _h: h } = this.#owner;
    for (let i = 0, n = this.size; i < n; i++) {
      yield this.#owner._takeString(m._aether_hs_embed_item_at(h, this.#which, i));
    }
  }

  toArray() { return [...this]; }
}

export class HtmlSanitizer {
  /**
   * Instantiate the wasm module (once per page — the instance is cached and
   * shared) and open a sanitizer handle.
   *
   * @param {object}  [opts]
   * @param {string}  [opts.wasmUrl]  override where htmlsanitizer.wasm is fetched from
   */
  static async create(opts = {}) {
    if (!modulePromise) {
      modulePromise = createModule(
        opts.wasmUrl ? { locateFile: () => opts.wasmUrl } : {});
    }
    return new HtmlSanitizer(await modulePromise);
  }

  constructor(module) {
    this._m = module;
    this._h = module._aether_hs_embed_new();
    if (!this._h) throw new Error('failed to create the native sanitizer');

    this.allowedTags = new AllowList(this, TAGS);
    this.allowedAttributes = new AllowList(this, ATTRIBUTES);
    this.allowedCssProperties = new AllowList(this, CSS_PROPERTIES);
    this.allowedSchemes = new AllowList(this, SCHEMES);
    this.allowedClasses = new AllowList(this, CLASSES);
    this.uriAttributes = new AllowList(this, URI_ATTRIBUTES);
  }

  // ---- internals ----

  /** Copy a JS string into wasm memory, run fn(ptr), always free. */
  _withCString(s, fn) {
    const p = this._m.stringToNewUTF8(String(s ?? ''));
    try { return fn(p); } finally { this._m._free(p); }
  }

  /** Read an ABI-returned string and free it through the ABI. */
  _takeString(ptr) {
    if (!ptr) return '';
    try { return this._m.UTF8ToString(ptr); }
    finally { this._m._aether_hs_embed_free_string(ptr); }
  }

  _check() { if (!this._h) throw new Error('sanitizer is closed'); }

  // ---- the main entry point ----

  /**
   * Clean an HTML fragment.
   * @param {string} html
   * @param {string} [baseUrl] resolve relative URLs against this
   * @returns {string}
   */
  sanitize(html, baseUrl = '') {
    this._check();
    const pHtml = this._m.stringToNewUTF8(String(html ?? ''));
    const pBase = this._m.stringToNewUTF8(String(baseUrl ?? ''));
    try {
      return this._takeString(
        this._m._aether_hs_embed_sanitize(this._h, pHtml, pBase));
    } finally {
      this._m._free(pHtml);
      this._m._free(pBase);
    }
  }

  /** As sanitize(), for a whole document. */
  sanitizeDocument(html, baseUrl = '') {
    this._check();
    const pHtml = this._m.stringToNewUTF8(String(html ?? ''));
    const pBase = this._m.stringToNewUTF8(String(baseUrl ?? ''));
    try {
      return this._takeString(
        this._m._aether_hs_embed_sanitize_document(this._h, pHtml, pBase));
    } finally {
      this._m._free(pHtml);
      this._m._free(pBase);
    }
  }

  /**
   * Sanitize straight into an element. Convenience for the common DOM case —
   * still goes through the same sanitizer core, so it is not a second code path.
   */
  setInnerHTML(el, html, baseUrl = '') {
    el.innerHTML = this.sanitize(html, baseUrl);
    return el;
  }

  // ---- flags ----

  get keepChildNodes() {
    return !!this._m._aether_hs_embed_get_keep_child_nodes(this._h);
  }
  set keepChildNodes(on) {
    this._m._aether_hs_embed_set_keep_child_nodes(this._h, on ? 1 : 0);
  }

  get allowDataAttributes() {
    return !!this._m._aether_hs_embed_get_allow_data_attributes(this._h);
  }
  set allowDataAttributes(on) {
    this._m._aether_hs_embed_set_allow_data_attributes(this._h, on ? 1 : 0);
  }

  get abiVersion() { return this._m._aether_hs_embed_abi_version(); }

  // ---- lifecycle ----

  /**
   * Release the wasm-side handle. Not strictly required for a page-lifetime
   * sanitizer, but the sanitizer core has a small per-sanitize allocation that is
   * only reclaimed when the handle goes, so long-running SPAs that create
   * sanitizers per view should close them.
   */
  close() {
    if (this._h) {
      this._m._aether_hs_embed_free(this._h);
      this._h = 0;
    }
  }
}

export default HtmlSanitizer;
