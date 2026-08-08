'use strict';
/**
 * The 12-check binding conformance suite (docs/conformance.md).
 *
 * Proves the JavaScript binding marshals every value shape across the FFI. It
 * is NOT a sanitizer test suite — the behavioural cases live in the engine's
 * own tests and run once, in Aether.
 *
 * Uses node:test + node:assert so no test framework has to be installed.
 */

const test = require('node:test');
const assert = require('node:assert');

const { HtmlSanitizer } = require('..');

/** Run `fn` with a fresh sanitizer, always closing it. */
function withSanitizer(fn) {
  const s = new HtmlSanitizer();
  try {
    return fn(s);
  } finally {
    s.close();
  }
}

test('01 script removed', () => withSanitizer((s) => {
  assert.strictEqual(
    s.sanitize('<div>Hello <script>alert(1)</script> world!</div>'),
    '<div>Hello  world!</div>');
}));

test('02 onclick removed', () => withSanitizer((s) => {
  assert.strictEqual(s.sanitize('<div onclick="alert(1)">Hello</div>'), '<div>Hello</div>');
}));

test('03 empty string', () => withSanitizer((s) => {
  assert.strictEqual(s.sanitize(''), '');
}));

test('04 utf-8 round trip', () => withSanitizer((s) => {
  assert.strictEqual(s.sanitize('<div>café ☕</div>'), '<div>café ☕</div>');
}));

test('05 allow custom tag', () => withSanitizer((s) => {
  assert.strictEqual(s.sanitize('<my-widget>x</my-widget>'), '');
  s.allowedTags.add('my-widget');
  assert.strictEqual(s.sanitize('<my-widget>x</my-widget>'), '<my-widget>x</my-widget>');
}));

test('06 disallow tag', () => withSanitizer((s) => {
  assert.strictEqual(s.sanitize('<div>x</div>'), '<div>x</div>');
  s.allowedTags.delete('div');
  assert.strictEqual(s.sanitize('<div>x</div>'), '');
}));

test('07 membership and count', () => withSanitizer((s) => {
  assert.ok(s.allowedSchemes.has('http'));
  assert.ok(!s.allowedSchemes.has('gopher'));
  assert.strictEqual(s.allowedSchemes.size, 2);
}));

test('08 enumeration', () => withSanitizer((s) => {
  assert.deepStrictEqual(s.allowedSchemes.toArray().sort(), ['http', 'https']);
}));

test('09 keep child nodes', () => withSanitizer((s) => {
  assert.strictEqual(
    s.sanitize('<div><nope>Hello <span>world</span></nope></div>'), '<div></div>');
  s.keepChildNodes = true;
  assert.strictEqual(s.keepChildNodes, true);
  assert.strictEqual(
    s.sanitize('<div><nope>Hello <span>world</span></nope></div>'),
    '<div>Hello <span>world</span></div>');
}));

test('10 on_removing_tag cancels', () => withSanitizer((s) => {
  const seen = [];
  s.onRemovingTag((node, reason) => {
    seen.push([node.name, reason]);
    return node.name === 'keep-me';
  });
  const out = s.sanitize('<div><keep-me>a</keep-me><drop-me>b</drop-me></div>');
  assert.strictEqual(out, '<div><keep-me>a</keep-me></div>');
  assert.deepStrictEqual(seen.find((x) => x[0] === 'keep-me'), ['keep-me', 0]);
  assert.deepStrictEqual(seen.find((x) => x[0] === 'drop-me'), ['drop-me', 0]);
}));

test('11 on_filter_url rewrites', () => withSanitizer((s) => {
  s.onFilterUrl((node, raw, resolved) => (
    resolved === 'https://example.com/logo.png'
      ? 'https://cdn.example.net/logo.png'
      : resolved));
  assert.strictEqual(
    s.sanitize('<img src="logo.png">', 'https://example.com'),
    '<img src="https://cdn.example.net/logo.png">');
}));

test('12 handles are independent', () => {
  const a = new HtmlSanitizer();
  const b = new HtmlSanitizer();
  try {
    a.allowedTags.add('only-in-a');
    assert.ok(a.allowedTags.has('only-in-a'));
    assert.ok(!b.allowedTags.has('only-in-a'));
  } finally {
    a.close();
    b.close();
  }
});

// ---- a few extras that exercise the remaining callback shapes ----

test('on_removing_attribute sees the attribute', () => withSanitizer((s) => {
  const seen = [];
  s.onRemovingAttribute((elem, attr, reason) => {
    seen.push([elem.name, attr.name, attr.value]);
    return false;
  });
  assert.strictEqual(s.sanitize('<div onclick="alert(1)">x</div>'), '<div>x</div>');
  assert.ok(seen.some(
    ([e, n, v]) => e === 'div' && n === 'onclick' && v === 'alert(1)'),
    `expected div/onclick/alert(1) in ${JSON.stringify(seen)}`);
}));

test('on_removing_comment cancels', () => withSanitizer((s) => {
  s.onRemovingComment(() => true);
  assert.strictEqual(
    s.sanitize('<div>a<!-- keep -->b</div>'), '<div>a<!-- keep -->b</div>');
}));

test('on_removing_style is four-arg', () => withSanitizer((s) => {
  const seen = [];
  s.onRemovingStyle((elem, name, value, reason) => {
    seen.push([name, value]);
    return name === '-custom-thing';
  });
  const out = s.sanitize('<div style="-custom-thing: 3; color: red">x</div>');
  assert.ok(out.includes('-custom-thing'), `got ${out}`);
  assert.ok(seen.some(([n, v]) => n === '-custom-thing' && v === '3'),
    `expected -custom-thing/3 in ${JSON.stringify(seen)}`);
}));

test('post_process_node visits', () => withSanitizer((s) => {
  const kinds = [];
  s.onPostProcessNode((node) => kinds.push(node.kind));
  s.sanitize('<div><span>a</span><span>b</span></div>');
  assert.ok(kinds.length > 0);
}));

test('node tree navigation', () => withSanitizer((s) => {
  const captured = {};
  s.onPostProcessDom((doc) => {
    captured.kind = doc.kind;
    captured.children = doc.children.length;
  });
  s.sanitize('<div>a</div><p>b</p>');
  assert.strictEqual(captured.kind, 1);          // NODE_DOCUMENT
  assert.ok(captured.children >= 2);
}));

test('abi version', () => withSanitizer((s) => {
  assert.ok(s.abiVersion >= 1);
}));

test('closed sanitizer rejects use', () => {
  const s = new HtmlSanitizer();
  s.close();
  assert.throws(() => s.sanitize('<div>x</div>'), /closed/);
});
