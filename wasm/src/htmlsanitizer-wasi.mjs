// Idiomatic JS surface over the ZIG-built wasm32-wasi module.
//
// The distinguishing feature vs htmlsanitizer.mjs (the Emscripten build):
// there is NO generated JS glue file. This drives the .wasm with the plain
// `WebAssembly` API and a ~30-line WASI shim, so the entire browser
// deliverable is one .wasm plus this file. Same sanitizer core, same ABI, same
// behaviour — just a different way of getting the bytes running.
//
//     import { HtmlSanitizer } from './htmlsanitizer-wasi.mjs';
//     const s = await HtmlSanitizer.create({ wasmUrl: './htmlsanitizer-wasi.wasm' });
//     el.innerHTML = s.sanitize(untrustedHtml);

export const TAGS = 0;
export const ATTRIBUTES = 1;
export const CSS_PROPERTIES = 2;
export const SCHEMES = 3;
export const CLASSES = 4;
export const URI_ATTRIBUTES = 5;

/**
 * Minimal wasi_snapshot_preview1 shim.
 *
 * The sanitizer is a pure string->string transform — no files, no sockets, no
 * clock that matters. These exist because wasi-libc references them, not
 * because the sanitizer core calls them on the sanitize path. Anything not listed is
 * proxied to a no-op returning 0 (WASI "success") rather than throwing, so an
 * unexercised libc corner can't take the page down.
 *
 * Deliberately NOT wired to anything real: this is the sandbox boundary. A
 * sanitizer that could read files would be a strictly worse sanitizer.
 */
function makeWasi(getMemory) {
  const dv = () => new DataView(getMemory().buffer);
  const impl = {
    proc_exit(code) { throw new Error(`wasm called proc_exit(${code})`); },
    fd_write(fd, iovs, iovsLen, nwritten) { dv().setUint32(nwritten, 0, true); return 0; },
    fd_read(fd, iovs, iovsLen, nread) { dv().setUint32(nread, 0, true); return 0; },
    fd_close() { return 0; },
    fd_seek() { return 0; },
    fd_fdstat_get() { return 0; },
    environ_get() { return 0; },
    environ_sizes_get(count, bufSize) {
      const d = dv(); d.setUint32(count, 0, true); d.setUint32(bufSize, 0, true); return 0;
    },
    args_get() { return 0; },
    args_sizes_get(count, bufSize) {
      const d = dv(); d.setUint32(count, 0, true); d.setUint32(bufSize, 0, true); return 0;
    },
    clock_time_get(id, precision, out) { dv().setBigUint64(out, 0n, true); return 0; },
    random_get(ptr, len) {
      const bytes = new Uint8Array(getMemory().buffer, ptr, len);
      (globalThis.crypto?.getRandomValues
        ? globalThis.crypto.getRandomValues(bytes)
        : bytes.fill(0));
      return 0;
    },
  };
  return new Proxy(impl, { get: (t, k) => (k in t ? t[k] : () => 0) });
}

let instancePromise = null;

class AllowList {
  #o; #w;
  constructor(owner, which) { this.#o = owner; this.#w = which; }
  add(item) { this.#o._withCString(item, (p) => this.#o._x.aether_hs_embed_allow(this.#o._h, this.#w, p)); return this; }
  delete(item) { this.#o._withCString(item, (p) => this.#o._x.aether_hs_embed_disallow(this.#o._h, this.#w, p)); return this; }
  has(item) { return !!this.#o._withCString(item, (p) => this.#o._x.aether_hs_embed_is_allowed(this.#o._h, this.#w, p)); }
  clear() { this.#o._x.aether_hs_embed_clear(this.#o._h, this.#w); return this; }
  get size() { return this.#o._x.aether_hs_embed_count(this.#o._h, this.#w); }
  *[Symbol.iterator]() {
    for (let i = 0, n = this.size; i < n; i++) {
      yield this.#o._takeString(this.#o._x.aether_hs_embed_item_at(this.#o._h, this.#w, i));
    }
  }
  toArray() { return [...this]; }
}

export class HtmlSanitizer {
  /**
   * @param {object} [opts]
   * @param {string|URL} [opts.wasmUrl]  where to fetch htmlsanitizer-wasi.wasm
   * @param {BufferSource} [opts.wasmBytes]  or supply the bytes directly
   */
  static async create(opts = {}) {
    if (!instancePromise) {
      instancePromise = (async () => {
        let bytes = opts.wasmBytes;
        if (!bytes) {
          const url = opts.wasmUrl ?? new URL('./htmlsanitizer-wasi.wasm', import.meta.url);
          bytes = await (await fetch(url)).arrayBuffer();
        }
        let memory;
        const { instance } = await WebAssembly.instantiate(
          bytes, { wasi_snapshot_preview1: makeWasi(() => memory) });
        memory = instance.exports.memory;
        // Reactor-model modules expose _initialize instead of _start.
        instance.exports._initialize?.();
        return instance;
      })();
    }
    return new HtmlSanitizer(await instancePromise);
  }

  constructor(instance) {
    this._inst = instance;
    this._x = instance.exports;
    this._mem = instance.exports.memory;
    this._enc = new TextEncoder();
    this._dec = new TextDecoder();

    this._h = this._x.aether_hs_embed_new();
    if (!this._h) throw new Error('failed to create the native sanitizer');

    this.allowedTags = new AllowList(this, TAGS);
    this.allowedAttributes = new AllowList(this, ATTRIBUTES);
    this.allowedCssProperties = new AllowList(this, CSS_PROPERTIES);
    this.allowedSchemes = new AllowList(this, SCHEMES);
    this.allowedClasses = new AllowList(this, CLASSES);
    this.uriAttributes = new AllowList(this, URI_ATTRIBUTES);
  }

  // ---- internals ----
  // NB: every view is created fresh from memory.buffer. A wasm memory.grow()
  // detaches previously-created ArrayBuffers, so caching a Uint8Array here
  // would break on the first large document.

  _toCString(s) {
    const b = this._enc.encode(String(s ?? ''));
    const p = this._x.malloc(b.length + 1);
    if (!p) throw new Error('wasm malloc failed');
    const u8 = new Uint8Array(this._mem.buffer);
    u8.set(b, p);
    u8[p + b.length] = 0;
    return p;
  }

  _withCString(s, fn) {
    const p = this._toCString(s);
    try { return fn(p); } finally { this._x.free(p); }
  }

  _readCString(p) {
    if (!p) return '';
    const u8 = new Uint8Array(this._mem.buffer);
    let e = p;
    while (u8[e] !== 0) e++;
    return this._dec.decode(u8.subarray(p, e));
  }

  _takeString(p) {
    if (!p) return '';
    try { return this._readCString(p); }
    finally { this._x.aether_hs_embed_free_string(p); }
  }

  _check() { if (!this._h) throw new Error('sanitizer is closed'); }

  // ---- API (mirrors htmlsanitizer.mjs exactly) ----

  sanitize(html, baseUrl = '') {
    this._check();
    const a = this._toCString(html), b = this._toCString(baseUrl);
    try { return this._takeString(this._x.aether_hs_embed_sanitize(this._h, a, b)); }
    finally { this._x.free(a); this._x.free(b); }
  }

  sanitizeDocument(html, baseUrl = '') {
    this._check();
    const a = this._toCString(html), b = this._toCString(baseUrl);
    try { return this._takeString(this._x.aether_hs_embed_sanitize_document(this._h, a, b)); }
    finally { this._x.free(a); this._x.free(b); }
  }

  setInnerHTML(el, html, baseUrl = '') {
    el.innerHTML = this.sanitize(html, baseUrl);
    return el;
  }

  get keepChildNodes() { return !!this._x.aether_hs_embed_get_keep_child_nodes(this._h); }
  set keepChildNodes(on) { this._x.aether_hs_embed_set_keep_child_nodes(this._h, on ? 1 : 0); }

  get allowDataAttributes() { return !!this._x.aether_hs_embed_get_allow_data_attributes(this._h); }
  set allowDataAttributes(on) { this._x.aether_hs_embed_set_allow_data_attributes(this._h, on ? 1 : 0); }

  get abiVersion() { return this._x.aether_hs_embed_abi_version(); }

  close() {
    if (this._h) { this._x.aether_hs_embed_free(this._h); this._h = 0; }
  }
}

export default HtmlSanitizer;
