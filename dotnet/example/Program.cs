// A short tour of the .NET binding. Run it with the engine built:
//
//   cd core && ae build --emit=lib embed.ae --extra _embed_support.c \
//       -o native/libhtmlsanitizer.so
//   cd ../dotnet && HTMLSANITIZER_LIB=../core/native/libhtmlsanitizer.so \
//       dotnet run --project example/Example.csproj

using System;

using HtmlSanitization;

using var s = new HtmlSanitizer();

Console.WriteLine($"engine: {HtmlSanitizer.NativeLibraryPath} (ABI v{HtmlSanitizer.AbiVersion})");

// 1. the defaults
Console.WriteLine(s.Sanitize("<div onclick=\"evil()\">Hello <script>x</script></div>"));
// <div>Hello </div>

// 2. teach it a custom element
s.AllowedTags.Add("my-widget");
Console.WriteLine(s.Sanitize("<my-widget>ok</my-widget>"));
// <my-widget>ok</my-widget>

// 3. keep the children of anything it removes
s.KeepChildNodes = true;
Console.WriteLine(s.Sanitize("<div><nope>Hello <span>world</span></nope></div>"));
// <div>Hello <span>world</span></div>

// 4. rewrite URLs as they are resolved
s.OnFilterUrl((elem, raw, resolved) =>
    resolved.StartsWith("https://example.com/", StringComparison.Ordinal)
        ? resolved.Replace("example.com", "cdn.example.net")
        : resolved);
Console.WriteLine(s.Sanitize("<img src=\"logo.png\">", "https://example.com/"));
// <img src="https://cdn.example.net/logo.png">

// 5. veto a removal — returning true KEEPS the node
s.OnRemovingTag((node, reason) => node.Name == "keep-me");
Console.WriteLine(s.Sanitize("<div><keep-me>a</keep-me></div>"));
// <div><keep-me>a</keep-me></div>

// 6. inspect the policy
Console.WriteLine($"schemes: {s.AllowedSchemes}");
Console.WriteLine($"tags: {s.AllowedTags.Count}");

// 7. one-shots, for when a handle is overkill
Console.WriteLine(HtmlSanitizer.SanitizeOnce("<p>hi<script>no</script></p>"));
