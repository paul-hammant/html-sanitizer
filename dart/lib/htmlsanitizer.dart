/// Clean HTML of constructs that can lead to Cross-Site Scripting (XSS).
///
/// A thin `dart:ffi` binding over the monorepo's one shared native sanitizer core
/// (`core/native/libhtmlsanitizer.so`, compiled from pure Aether). It contains
/// **no sanitizer logic**: every member marshals to an `aether_hs_embed_*`
/// call. One sanitizer core, one set of behaviours, N language surfaces.
///
/// ```dart
/// import 'package:htmlsanitizer/htmlsanitizer.dart';
///
/// final s = HtmlSanitizer();
/// print(s.sanitize('<div onclick="alert(1)">Hello</div>'));  // <div>Hello</div>
/// s.close();
/// ```
library;

export 'src/sanitizer.dart'
    show
        Attribute,
        AllowList,
        FilterUrlHandler,
        HtmlSanitizer,
        Node,
        NodeKind,
        PostProcessHandler,
        Reason,
        RemovingAttributeHandler,
        RemovingCommentHandler,
        RemovingStyleHandler,
        RemovingTagHandler,
        sanitize,
        sanitizeDocument;
