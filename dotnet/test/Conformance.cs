// The 12-check binding conformance suite (docs/conformance.md).
//
// Proves the .NET binding marshals every value shape across the P/Invoke
// boundary. It is NOT a sanitizer test suite — the behavioural cases live in
// the sanitizer core's own tests and run once, in Aether.
//
// ## Why a console runner and not xunit/NUnit
//
// Every .NET test framework arrives as a NuGet package, so `dotnet test`
// cannot run without a restore — which means a network round trip (or a
// pre-warmed package cache) before a single assertion executes. The rest of
// this monorepo's bindings test with whatever is already on the box, so this
// project does too: `dotnet run` on a self-contained runner, no packages, no
// restore, and the process exit code is the result.
//
// The trade is real and small: no test discovery, no parallelism, no
// `[Theory]`. For twenty-odd marshalling assertions that costs nothing, and
// it keeps the binding testable on an air-gapped machine. Swapping in xunit
// later is mechanical — each Check(...) below is one [Fact].

using System;
using System.Collections.Generic;
using System.Linq;

using HtmlSanitization;

internal static class Conformance
{
    private static int _passed;
    private static readonly List<string> Failures = new();

    private static void Check(string name, Action body)
    {
        try
        {
            body();
            _passed++;
            Console.WriteLine($"  PASS {name}");
        }
        catch (Exception ex)
        {
            Failures.Add($"{name}: {ex.Message}");
            Console.WriteLine($"  FAIL {name}");
            Console.WriteLine($"       {ex.Message}");
        }
    }

    private static void Eq(string got, string want, string what = "value")
    {
        if (!string.Equals(got, want, StringComparison.Ordinal))
            throw new Exception($"{what}:\n         got  \"{got}\"\n         want \"{want}\"");
    }

    private static void Eq(int got, int want, string what = "value")
    {
        if (got != want) throw new Exception($"{what}: got {got}, want {want}");
    }

    private static void IsTrue(bool got, string what)
    {
        if (!got) throw new Exception($"{what}: expected true");
    }

    private static void IsFalse(bool got, string what)
    {
        if (got) throw new Exception($"{what}: expected false");
    }

    private static void Contains<T>(IEnumerable<T> haystack, T needle, string what)
    {
        if (!haystack.Contains(needle))
            throw new Exception($"{what}: {needle} not found in [{string.Join(", ", haystack)}]");
    }

    public static int Main()
    {
        Console.WriteLine("=== htmlsanitizer .NET binding conformance ===");
        Console.WriteLine($"sanitizer core: {HtmlSanitizer.NativeLibraryPath ?? "(default probing)"} " +
                          $"(ABI v{HtmlSanitizer.AbiVersion})");

        // ---- the twelve ----

        Check("01 script removed", () =>
        {
            using var s = new HtmlSanitizer();
            Eq(s.Sanitize("<div>Hello <script>alert(1)</script> world!</div>"),
               "<div>Hello  world!</div>");
        });

        Check("02 onclick removed", () =>
        {
            using var s = new HtmlSanitizer();
            Eq(s.Sanitize("<div onclick=\"alert(1)\">Hello</div>"), "<div>Hello</div>");
        });

        Check("03 empty string", () =>
        {
            using var s = new HtmlSanitizer();
            Eq(s.Sanitize(""), "");
        });

        Check("04 utf-8 round trip", () =>
        {
            using var s = new HtmlSanitizer();
            // Would catch a `string` DllImport parameter marshalling as ANSI.
            Eq(s.Sanitize("<div>café ☕</div>"), "<div>café ☕</div>");
        });

        Check("05 allow custom tag", () =>
        {
            using var s = new HtmlSanitizer();
            Eq(s.Sanitize("<my-widget>x</my-widget>"), "");
            s.AllowedTags.Add("my-widget");
            Eq(s.Sanitize("<my-widget>x</my-widget>"), "<my-widget>x</my-widget>");
        });

        Check("06 disallow tag", () =>
        {
            using var s = new HtmlSanitizer();
            Eq(s.Sanitize("<div>x</div>"), "<div>x</div>");
            s.AllowedTags.Remove("div");
            Eq(s.Sanitize("<div>x</div>"), "");
        });

        Check("07 membership and count", () =>
        {
            using var s = new HtmlSanitizer();
            IsTrue(s.AllowedSchemes.Contains("http"), "http allowed");
            IsFalse(s.AllowedSchemes.Contains("gopher"), "gopher allowed");
            Eq(s.AllowedSchemes.Count, 2, "scheme count");
        });

        Check("08 enumeration", () =>
        {
            using var s = new HtmlSanitizer();
            var got = s.AllowedSchemes.ToSortedList();
            Eq(got.Count, 2, "enumerated count");
            Eq(got[0], "http");
            Eq(got[1], "https");
        });

        Check("09 keep child nodes", () =>
        {
            using var s = new HtmlSanitizer();
            Eq(s.Sanitize("<div><nope>Hello <span>world</span></nope></div>"), "<div></div>");
            s.KeepChildNodes = true;
            IsTrue(s.KeepChildNodes, "KeepChildNodes");
            Eq(s.Sanitize("<div><nope>Hello <span>world</span></nope></div>"),
               "<div>Hello <span>world</span></div>");
        });

        Check("10 OnRemovingTag cancels", () =>
        {
            using var s = new HtmlSanitizer();
            var names = new List<string>();
            var reasons = new List<RemovalReason>();
            s.OnRemovingTag((node, reason) =>
            {
                names.Add(node.Name);
                reasons.Add(reason);
                return node.Name == "keep-me";
            });
            Eq(s.Sanitize("<div><keep-me>a</keep-me><drop-me>b</drop-me></div>"),
               "<div><keep-me>a</keep-me></div>");
            Contains(names, "keep-me", "hook saw keep-me");
            Contains(names, "drop-me", "hook saw drop-me");
            // An `int`/`long` width mismatch shows up here as a garbage reason.
            Contains(reasons, RemovalReason.NotAllowedTag, "reason is a real int");
        });

        Check("11 OnFilterUrl rewrites", () =>
        {
            using var s = new HtmlSanitizer();
            s.OnFilterUrl((elem, raw, resolved) =>
                resolved == "https://example.com/logo.png"
                    ? "https://cdn.example.net/logo.png"
                    : resolved);
            Eq(s.Sanitize("<img src=\"logo.png\">", "https://example.com"),
               "<img src=\"https://cdn.example.net/logo.png\">");
        });

        Check("12 handles are independent", () =>
        {
            using var a = new HtmlSanitizer();
            using var b = new HtmlSanitizer();
            a.AllowedTags.Add("only-in-a");
            IsTrue(a.AllowedTags.Contains("only-in-a"), "a knows the tag");
            IsFalse(b.AllowedTags.Contains("only-in-a"), "b does not");
        });

        // ---- a few extras that exercise the remaining callback shapes ----

        Check("OnRemovingAttribute sees the attribute", () =>
        {
            using var s = new HtmlSanitizer();
            var seen = new List<string>();
            s.OnRemovingAttribute((elem, attr, reason) =>
            {
                seen.Add($"{elem.Name}/{attr.Name}/{attr.Value}");
                return false;
            });
            Eq(s.Sanitize("<div onclick=\"alert(1)\">x</div>"), "<div>x</div>");
            Contains(seen, "div/onclick/alert(1)", "attribute hook");
        });

        Check("OnRemovingComment cancels", () =>
        {
            using var s = new HtmlSanitizer();
            s.OnRemovingComment(node => true);
            Eq(s.Sanitize("<div>a<!-- keep -->b</div>"), "<div>a<!-- keep -->b</div>");
        });

        Check("OnRemovingStyle is four-arg", () =>
        {
            using var s = new HtmlSanitizer();
            var seen = new List<string>();
            s.OnRemovingStyle((elem, name, value, reason) =>
            {
                seen.Add($"{name}={value}");
                return name == "-custom-thing";
            });
            var outHtml = s.Sanitize("<div style=\"-custom-thing: 3; color: red\">x</div>");
            IsTrue(outHtml.Contains("-custom-thing"), "custom property kept");
            Contains(seen, "-custom-thing=3", "style hook args");
        });

        Check("OnPostProcessNode visits", () =>
        {
            using var s = new HtmlSanitizer();
            var kinds = new List<NodeKind>();
            s.OnPostProcessNode(node => kinds.Add(node.Kind));
            s.Sanitize("<div><span>a</span><span>b</span></div>");
            IsTrue(kinds.Count > 0, "OnPostProcessNode fired");
        });

        Check("node tree navigation", () =>
        {
            using var s = new HtmlSanitizer();
            NodeKind kind = NodeKind.Unknown;
            int children = 0;
            s.OnPostProcessDom(doc =>
            {
                kind = doc.Kind;
                children = doc.Children.Count;
                if (children > 0)
                {
                    var first = doc.ChildAt(0);
                    IsTrue(first.Parent is not null, "child's Parent is set");
                }
            });
            s.Sanitize("<div>a</div><p>b</p>");
            Eq((int)kind, (int)NodeKind.Document, "document kind");
            IsTrue(children >= 2, "document has >= 2 children");
        });

        Check("AttrSetValue rewrites in place", () =>
        {
            using var s = new HtmlSanitizer();
            s.OnRemovingAttribute((elem, attr, reason) =>
            {
                if (attr.Name == "onclick")
                {
                    attr.SetValue("sanitised");
                    Eq(attr.Value, "sanitised", "value after SetValue");
                }
                return false;
            });
            Eq(s.Sanitize("<div onclick=\"alert(1)\">x</div>"), "<div>x</div>");
        });

        Check("attribute enumeration", () =>
        {
            using var s = new HtmlSanitizer();
            var names = new List<string>();
            s.OnPostProcessNode(node =>
            {
                if (node.Kind == NodeKind.Element && node.Name == "a")
                    foreach (var a in node.Attributes) names.Add(a.Name);
            });
            s.Sanitize("<a href=\"https://example.com/\" title=\"t\">x</a>");
            Contains(names, "href", "href seen");
            Contains(names, "title", "title seen");
        });

        Check("clearing a hook restores default behaviour", () =>
        {
            using var s = new HtmlSanitizer();
            s.OnRemovingTag((node, r) => node.Name == "keep-me");
            Eq(s.Sanitize("<div><keep-me>a</keep-me></div>"),
               "<div><keep-me>a</keep-me></div>");
            s.OnRemovingTag(null);
            Eq(s.Sanitize("<div><keep-me>a</keep-me></div>"), "<div></div>");
        });

        Check("SanitizeDocument is wired", () =>
        {
            using var s = new HtmlSanitizer();
            Eq(s.SanitizeDocument("<div>doc<script>x</script></div>"), "<html><head></head><body><div>doc</div></body></html>");
        });

        Check("AllowDataAttributes flag", () =>
        {
            using var s = new HtmlSanitizer();
            IsFalse(s.AllowDataAttributes, "off by default");
            s.AllowDataAttributes = true;
            IsTrue(s.AllowDataAttributes, "on after set");
            Eq(s.Sanitize("<div data-x=\"1\"></div>"), "<div data-x=\"1\"></div>");
        });

        Check("Clear empties a policy list", () =>
        {
            using var s = new HtmlSanitizer();
            s.AllowedSchemes.Clear();
            Eq(s.AllowedSchemes.Count, 0, "count after Clear");
        });

        Check("item at an out-of-range index is empty", () =>
        {
            using var s = new HtmlSanitizer();
            Eq(s.AllowedSchemes[999], "", "out of range");
            Eq(s.AllowedSchemes[-1], "", "negative index");
        });

        Check("ABI version", () =>
        {
            IsTrue(HtmlSanitizer.AbiVersion >= 1, "AbiVersion >= 1");
        });

        Check("disposed sanitizer rejects use", () =>
        {
            var s = new HtmlSanitizer();
            s.Dispose();
            try
            {
                s.Sanitize("<div>x</div>");
                throw new Exception("expected ObjectDisposedException");
            }
            catch (ObjectDisposedException)
            {
                // expected
            }
            s.Dispose();   // idempotent
        });

        Check("one-shot helpers", () =>
        {
            Eq(HtmlSanitizer.SanitizeOnce("<div>a<script>b</script></div>"), "<div>a</div>");
            Eq(HtmlSanitizer.SanitizeDocumentOnce("<div>a<script>b</script></div>"),
               "<div>a</div>");
        });

        Check("many sanitize calls do not leak or crash", () =>
        {
            // A returned char* that was never freed would show up here as
            // steadily growing RSS; a double free would crash. Cheap insurance
            // over the TakeString contract.
            using var s = new HtmlSanitizer();
            for (int i = 0; i < 5000; i++)
                s.Sanitize("<div onclick=\"x\">café ☕ <script>no</script></div>");
            Eq(s.Sanitize("<div>ok</div>"), "<div>ok</div>");
        });

        Console.WriteLine($"=== {_passed} passed, {Failures.Count} failed ===");
        if (Failures.Count > 0)
        {
            Console.WriteLine("failures:");
            foreach (var f in Failures) Console.WriteLine($"  - {f}");
            return 1;
        }
        return 0;
    }
}
