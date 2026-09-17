"""A third-party consumer of the INSTALLED htmlsanitizer package.

Run by python/.example.ae inside a clean venv with HTMLSANITIZER_LIB unset, so
only the .so bundled inside the wheel can satisfy the load. That is the honest
"pip install and it just works" test — python/.tests.ae cannot give it, because
it runs against the source tree with the .so handed in via env var.

    python consumer_example.py explicit    # pass the .so path in by hand
    python consumer_example.py discovery   # zero-config; find the bundled .so
"""
import os
import sys

from htmlsanitizer import HtmlSanitizer

DIRTY = '<div onclick="steal()">hi <script>alert(1)</script><a href="/p">x</a></div>'
CLEAN = '<div>hi <a href="https://example.com/p">x</a></div>'


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "discovery"

    if mode == "explicit":
        # The first-class argument: a consumer that keeps the sanitizer core somewhere
        # of its own choosing points at it directly.
        import htmlsanitizer as pkg
        bundled = os.path.join(os.path.dirname(pkg.__file__),
                               "native", "libhtmlsanitizer.so")
        s = HtmlSanitizer(native_lib=bundled)
    else:
        # Zero-config: the installed package finds its own bundled .so.
        s = HtmlSanitizer()

    with s:
        got = s.sanitize(DIRTY, "https://example.com")
        if got != CLEAN:
            print("FAIL ({}): got {!r}, want {!r}".format(mode, got, CLEAN))
            return 1

        # Prove configuration and callbacks survive the packaging boundary too.
        s.allowed_tags.add("my-widget")
        if s.sanitize("<my-widget>x</my-widget>") != "<my-widget>x</my-widget>":
            print("FAIL ({}): allow-list mutation did not take".format(mode))
            return 1

        s.on_removing_tag(lambda node, reason: node.name == "keep-me")
        if s.sanitize("<keep-me>a</keep-me>") != "<keep-me>a</keep-me>":
            print("FAIL ({}): callback did not fire".format(mode))
            return 1

    print("PASS ({}): installed wheel sanitized, configured and called back".format(mode))
    return 0


if __name__ == "__main__":
    sys.exit(main())
