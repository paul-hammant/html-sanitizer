// The 12-check binding conformance suite (docs/conformance.md), plus the
// WASM-specific concerns: module instantiation, memory growth, and that the
// sanitizer core's security fixes rode along into the wasm32 build.
//
// Checks 10 and 11 (the callback hooks) are NOT covered — see the README.
// Emscripten can do callbacks via addFunction, but that needs -sALLOW_TABLE_GROWTH
// and a reserved table, which costs bundle size for a feature a DOM sanitizer
// rarely wants. Omitted deliberately, not forgotten.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { HtmlSanitizer } from '../dist/htmlsanitizer.mjs';

const s = await HtmlSanitizer.create();

test('01 script removed', () => {
  assert.equal(s.sanitize('<div>Hello <script>alert(1)</script> world!</div>'),
               '<div>Hello  world!</div>');
});

test('02 onclick removed', () => {
  assert.equal(s.sanitize('<div onclick="alert(1)">Hello</div>'), '<div>Hello</div>');
});

test('03 empty string', () => {
  assert.equal(s.sanitize(''), '');
});

test('04 utf-8 round trip', () => {
  assert.equal(s.sanitize('<div>café ☕</div>'), '<div>café ☕</div>');
});

test('05 allow a custom tag', () => {
  const t = await_fresh();
  assert.equal(t.sanitize('<my-widget>x</my-widget>'), '');
  t.allowedTags.add('my-widget');
  assert.equal(t.sanitize('<my-widget>x</my-widget>'), '<my-widget>x</my-widget>');
  t.close();
});

test('06 disallow a default tag', () => {
  const t = await_fresh();
  assert.equal(t.sanitize('<div>x</div>'), '<div>x</div>');
  t.allowedTags.delete('div');
  assert.equal(t.sanitize('<div>x</div>'), '');
  t.close();
});

test('07 membership and count', () => {
  assert.equal(s.allowedSchemes.has('http'), true);
  assert.equal(s.allowedSchemes.has('gopher'), false);
  assert.equal(s.allowedSchemes.size, 2);
});

test('08 enumeration', () => {
  assert.deepEqual(s.allowedSchemes.toArray().sort(), ['http', 'https']);
});

test('09 keepChildNodes', () => {
  const t = await_fresh();
  assert.equal(t.sanitize('<div><nope>Hello <span>world</span></nope></div>'), '<div></div>');
  t.keepChildNodes = true;
  assert.equal(t.keepChildNodes, true);
  assert.equal(t.sanitize('<div><nope>Hello <span>world</span></nope></div>'),
               '<div>Hello <span>world</span></div>');
  t.close();
});

// 10 and 11 (callbacks) intentionally not covered — see the file header.

test('12 handles are independent', () => {
  const a = await_fresh(), b = await_fresh();
  a.allowedTags.add('only-in-a');
  assert.equal(a.allowedTags.has('only-in-a'), true);
  assert.equal(b.allowedTags.has('only-in-a'), false);
  a.close(); b.close();
});

// ---- URL handling ----

test('relative URL resolved against a base', () => {
  assert.equal(s.sanitize('<a href="/page">x</a>', 'https://example.com'),
               '<a href="https://example.com/page">x</a>');
});

test('protocol-relative URL resolved', () => {
  assert.equal(s.sanitize('<a href="//evil.example/p">x</a>', 'https://example.com'),
               '<a href="https://evil.example/p">x</a>');
});

// ---- the sanitizer core's security fixes must be present in the wasm build too ----

test('SECURITY javascript: blocked', () => {
  assert.equal(s.sanitize('<a href="javascript:alert(1)">x</a>'), '<a>x</a>');
});

test('SECURITY leading-space javascript: blocked', () => {
  // Regression: get_scheme used to see the space, report "no scheme", and
  // let the URL through as relative — while browsers strip it and execute.
  assert.equal(s.sanitize('<a href=" javascript:alert(1)">x</a>'), '<a>x</a>');
});

test('SECURITY entity-encoded javascript: blocked', () => {
  assert.equal(s.sanitize('<a href="&#106;avascript:alert(1)">x</a>'), '<a>x</a>');
});

test('SECURITY stray < does not hang the tokenizer', () => {
  // Regression: this used to spin forever (zero bytes consumed per pass).
  assert.equal(s.sanitize('<<a>'), '&lt;<a></a>');
});

test('SECURITY event handlers stripped', () => {
  assert.equal(s.sanitize('<img src=x onerror=alert(1)>'), '<img src="x">');
});

test('SECURITY iframe removed', () => {
  assert.equal(s.sanitize('<iframe src="//evil.example"></iframe>'), '');
});

// ---- wasm-specific ----

test('abiVersion is readable', () => {
  assert.ok(s.abiVersion >= 1);
});

test('a large document does not corrupt memory (ALLOW_MEMORY_GROWTH)', () => {
  const big = '<div>' + '<p>hello <script>bad()</script></p>'.repeat(5000) + '</div>';
  const out = s.sanitize(big);
  assert.ok(!out.includes('<script'));
  assert.ok(!out.includes('bad()'));
  assert.ok(out.length > 1000);
});

test('use after close throws', () => {
  const t = await_fresh();
  t.close();
  assert.throws(() => t.sanitize('<div>x</div>'), /closed/);
});

test('repeated sanitize is stable', () => {
  for (let i = 0; i < 200; i++) {
    assert.equal(s.sanitize('<b onclick=x>hi</b>'), '<b>hi</b>');
  }
});

// The module instance is shared and already resolved by now, so opening
// another handle is synchronous.
function await_fresh() {
  return new HtmlSanitizer(s._m);
}
