// A short tour of the Dart binding. Run it with the engine built:
//
//   cd core && ae build --emit=lib embed.ae --extra _embed_support.c \
//       -o native/libhtmlsanitizer.so
//   cd ../dart && dart pub get && dart run example/main.dart

import 'package:htmlsanitizer/htmlsanitizer.dart';

void main() {
  final s = HtmlSanitizer();
  try {
    print('engine: ${s.nativeLibraryPath} (ABI v${s.abiVersion})');

    // 1. the defaults
    print(s.sanitize('<div onclick="evil()">Hello <script>x</script></div>'));
    // <div>Hello </div>

    // 2. teach it a custom element
    s.allowedTags.add('my-widget');
    print(s.sanitize('<my-widget>ok</my-widget>'));
    // <my-widget>ok</my-widget>

    // 3. keep the children of anything it removes
    s.keepChildNodes = true;
    print(s.sanitize('<div><nope>Hello <span>world</span></nope></div>'));
    // <div>Hello <span>world</span></div>

    // 4. rewrite URLs as they are resolved
    s.onFilterUrl((elem, raw, resolved) =>
        resolved.startsWith('https://example.com/')
            ? resolved.replaceFirst('example.com', 'cdn.example.net')
            : resolved);
    print(s.sanitize('<img src="logo.png">', 'https://example.com/'));
    // <img src="https://cdn.example.net/logo.png">

    // 5. veto a removal — returning true KEEPS the node
    s.onRemovingTag((node, reason) => node.name == 'keep-me');
    print(s.sanitize('<div><keep-me>a</keep-me><drop-me>b</drop-me></div>'));
    // <div><keep-me>a</keep-me></div>

    // 6. inspect the policy
    print('schemes: ${s.allowedSchemes.toSortedList()}');
    print('tags: ${s.allowedTags.length}');
  } finally {
    s.close();
  }
}
