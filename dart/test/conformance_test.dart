/// The 12-check binding conformance suite (docs/conformance.md).
///
/// Proves the Dart binding marshals every value shape across the FFI. It is
/// NOT a sanitizer test suite — the behavioural cases live in the engine's own
/// tests and run once, in Aether.
@TestOn('vm')
library;

import 'package:htmlsanitizer/htmlsanitizer.dart';
import 'package:test/test.dart';

void main() {
  late HtmlSanitizer s;

  setUp(() => s = HtmlSanitizer());
  tearDown(() => s.close());

  // ---- the twelve ----

  test('01 script removed', () {
    expect(s.sanitize('<div>Hello <script>alert(1)</script> world!</div>'),
        equals('<div>Hello  world!</div>'));
  });

  test('02 onclick removed', () {
    expect(s.sanitize('<div onclick="alert(1)">Hello</div>'),
        equals('<div>Hello</div>'));
  });

  test('03 empty string', () {
    expect(s.sanitize(''), equals(''));
  });

  test('04 utf-8 round trip', () {
    expect(s.sanitize('<div>café ☕</div>'), equals('<div>café ☕</div>'));
  });

  test('05 allow custom tag', () {
    expect(s.sanitize('<my-widget>x</my-widget>'), equals(''));
    s.allowedTags.add('my-widget');
    expect(s.sanitize('<my-widget>x</my-widget>'),
        equals('<my-widget>x</my-widget>'));
  });

  test('06 disallow tag', () {
    expect(s.sanitize('<div>x</div>'), equals('<div>x</div>'));
    s.allowedTags.remove('div');
    expect(s.sanitize('<div>x</div>'), equals(''));
  });

  test('07 membership and count', () {
    expect(s.allowedSchemes.contains('http'), isTrue);
    expect(s.allowedSchemes.contains('gopher'), isFalse);
    expect(s.allowedSchemes.length, equals(2));
  });

  test('08 enumeration', () {
    expect(s.allowedSchemes.toSortedList(), equals(['http', 'https']));
  });

  test('09 keep child nodes', () {
    expect(s.sanitize('<div><nope>Hello <span>world</span></nope></div>'),
        equals('<div></div>'));
    s.keepChildNodes = true;
    expect(s.keepChildNodes, isTrue);
    expect(s.sanitize('<div><nope>Hello <span>world</span></nope></div>'),
        equals('<div>Hello <span>world</span></div>'));
  });

  test('10 on_removing_tag cancels', () {
    final seen = <(String, Reason)>[];
    s.onRemovingTag((node, reason) {
      seen.add((node.name, reason));
      return node.name == 'keep-me';
    });
    expect(s.sanitize('<div><keep-me>a</keep-me><drop-me>b</drop-me></div>'),
        equals('<div><keep-me>a</keep-me></div>'));
    expect(seen, contains(('keep-me', Reason.notAllowedTag)));
    expect(seen, contains(('drop-me', Reason.notAllowedTag)));
  });

  test('11 on_filter_url rewrites', () {
    s.onFilterUrl((elem, raw, resolved) =>
        resolved == 'https://example.com/logo.png'
            ? 'https://cdn.example.net/logo.png'
            : resolved);
    expect(s.sanitize('<img src="logo.png">', 'https://example.com'),
        equals('<img src="https://cdn.example.net/logo.png">'));
  });

  test('12 handles are independent', () {
    final a = HtmlSanitizer();
    final b = HtmlSanitizer();
    try {
      a.allowedTags.add('only-in-a');
      expect(a.allowedTags.contains('only-in-a'), isTrue);
      expect(b.allowedTags.contains('only-in-a'), isFalse);
    } finally {
      a.close();
      b.close();
    }
  });

  // ---- a few extras that exercise the remaining callback shapes ----

  test('on_removing_attribute sees the attribute', () {
    final seen = <(String, String, String)>[];
    s.onRemovingAttribute((elem, attr, reason) {
      seen.add((elem.name, attr.name, attr.value));
      return false;
    });
    expect(
        s.sanitize('<div onclick="alert(1)">x</div>'), equals('<div>x</div>'));
    expect(seen, contains(('div', 'onclick', 'alert(1)')));
  });

  test('on_removing_comment cancels', () {
    s.onRemovingComment((node) => true);
    expect(s.sanitize('<div>a<!-- keep -->b</div>'),
        equals('<div>a<!-- keep -->b</div>'));
  });

  test('on_removing_style is four-arg', () {
    final seen = <(String, String)>[];
    s.onRemovingStyle((elem, name, value, reason) {
      seen.add((name, value));
      return name == '-custom-thing';
    });
    final out = s.sanitize('<div style="-custom-thing: 3; color: red">x</div>');
    expect(out, contains('-custom-thing'));
    expect(seen, contains(('-custom-thing', '3')));
  });

  test('post_process_node visits', () {
    final kinds = <NodeKind>[];
    s.onPostProcessNode((node) => kinds.add(node.kind));
    s.sanitize('<div><span>a</span><span>b</span></div>');
    expect(kinds, isNotEmpty);
  });

  test('node tree navigation', () {
    NodeKind? kind;
    int? children;
    s.onPostProcessDom((doc) {
      kind = doc.kind;
      children = doc.children.length;
    });
    s.sanitize('<div>a</div><p>b</p>');
    expect(kind, equals(NodeKind.document));
    expect(children, greaterThanOrEqualTo(2));
  });

  test('attr_set_value rewrites in place', () {
    s.onRemovingAttribute((elem, attr, reason) {
      if (attr.name == 'onclick') {
        attr.value = 'sanitised';
        expect(attr.value, equals('sanitised'));
      }
      return false;
    });
    expect(
        s.sanitize('<div onclick="alert(1)">x</div>'), equals('<div>x</div>'));
  });

  test('clearing a hook restores default behaviour', () {
    s.onRemovingTag((node, reason) => node.name == 'keep-me');
    expect(s.sanitize('<div><keep-me>a</keep-me></div>'),
        equals('<div><keep-me>a</keep-me></div>'));
    s.onRemovingTag(null);
    expect(s.sanitize('<div><keep-me>a</keep-me></div>'), equals('<div></div>'));
  });

  test('sanitize_document is wired', () {
    expect(s.sanitizeDocument('<div>doc<script>x</script></div>'),
        equals('<html><head></head><body><div>doc</div></body></html>'));
  });

  test('allow_data_attributes flag', () {
    expect(s.allowDataAttributes, isFalse);
    s.allowDataAttributes = true;
    expect(s.allowDataAttributes, isTrue);
    expect(s.sanitize('<div data-x="1"></div>'), equals('<div data-x="1"></div>'));
  });

  test('clear empties a policy list', () {
    s.allowedSchemes.clear();
    expect(s.allowedSchemes.length, equals(0));
    expect(s.allowedSchemes.isEmpty, isTrue);
  });

  test('abi version', () {
    expect(s.abiVersion, greaterThanOrEqualTo(1));
  });

  test('closed sanitizer rejects use', () {
    final closed = HtmlSanitizer();
    closed.close();
    expect(() => closed.sanitize('<div>x</div>'), throwsStateError);
    closed.close(); // idempotent
  });

  test('one-shot helpers', () {
    expect(sanitize('<div>a<script>b</script></div>'), equals('<div>a</div>'));
    expect(sanitizeDocument('<div>a<script>b</script></div>'),
        equals('<html><head></head><body><div>a</div></body></html>'));
  });
}
