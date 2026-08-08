package org.htmlsanitizer;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.function.Consumer;

/**
 * The 12-check binding conformance suite (docs/conformance.md).
 *
 * <p>Proves the Java binding marshals every value shape across the FFI. It is
 * NOT a sanitizer test suite — the behavioural cases live in the engine's own
 * tests and run once, in Aether.
 *
 * <h2>Why a main-method runner instead of JUnit</h2>
 * This suite must run with nothing but a JDK, so {@code java/.tests.ae} works
 * offline and without Maven resolving anything. The assertions here are a
 * dozen lines; a test framework would be the only thing in the whole binding
 * that needed a network fetch. {@code java/pom.xml} still declares JUnit 5 for
 * downstream consumers who want to run this class under Maven — the checks
 * are plain methods, so wrapping them in {@code @Test} is mechanical.
 *
 * <p>Run:
 * <pre>{@code
 * javac -d out $(find src -name '*.java')
 * HTMLSANITIZER_LIB=... java --enable-native-access=ALL-UNNAMED \
 *     -cp out org.htmlsanitizer.ConformanceTest
 * }</pre>
 */
public final class ConformanceTest {

    private static int passed = 0;
    private static final List<String> failures = new ArrayList<>();

    public static void main(String[] args) {
        // ---- the 12 required checks ----
        check("01 script removed", s ->
                assertEquals("<div>Hello  world!</div>",
                        s.sanitize("<div>Hello <script>alert(1)</script> world!</div>")));

        check("02 onclick removed", s ->
                assertEquals("<div>Hello</div>",
                        s.sanitize("<div onclick=\"alert(1)\">Hello</div>")));

        check("03 empty string", s -> assertEquals("", s.sanitize("")));

        check("04 utf-8 round trip", s ->
                assertEquals("<div>café ☕</div>", s.sanitize("<div>café ☕</div>")));

        check("05 allow custom tag", s -> {
            assertEquals("", s.sanitize("<my-widget>x</my-widget>"));
            s.allowedTags().add("my-widget");
            assertEquals("<my-widget>x</my-widget>", s.sanitize("<my-widget>x</my-widget>"));
        });

        check("06 disallow tag", s -> {
            assertEquals("<div>x</div>", s.sanitize("<div>x</div>"));
            s.allowedTags().remove("div");
            assertEquals("", s.sanitize("<div>x</div>"));
        });

        check("07 membership and count", s -> {
            assertTrue("http is allowed", s.allowedSchemes().contains("http"));
            assertTrue("gopher is not", !s.allowedSchemes().contains("gopher"));
            assertEquals(2, s.allowedSchemes().size());
        });

        check("08 enumeration", s -> {
            List<String> got = s.allowedSchemes().toList();
            Collections.sort(got);
            assertEquals(List.of("http", "https").toString(), got.toString());
        });

        check("09 keep child nodes", s -> {
            assertEquals("<div></div>",
                    s.sanitize("<div><nope>Hello <span>world</span></nope></div>"));
            s.keepChildNodes(true);
            assertTrue("flag reads back", s.keepChildNodes());
            assertEquals("<div>Hello <span>world</span></div>",
                    s.sanitize("<div><nope>Hello <span>world</span></nope></div>"));
        });

        check("10 on_removing_tag cancels", s -> {
            List<String> seen = new ArrayList<>();
            s.onRemovingTag((node, reason) -> {
                seen.add(node.name() + "/" + reason);
                return node.name().equals("keep-me");
            });
            assertEquals("<div><keep-me>a</keep-me></div>",
                    s.sanitize("<div><keep-me>a</keep-me><drop-me>b</drop-me></div>"));
            assertTrue("saw keep-me/0 in " + seen, seen.contains("keep-me/0"));
            assertTrue("saw drop-me/0 in " + seen, seen.contains("drop-me/0"));
        });

        check("11 on_filter_url rewrites", s -> {
            s.onFilterUrl((node, raw, resolved) ->
                    resolved.equals("https://example.com/logo.png")
                            ? "https://cdn.example.net/logo.png"
                            : resolved);
            assertEquals("<img src=\"https://cdn.example.net/logo.png\">",
                    s.sanitize("<img src=\"logo.png\">", "https://example.com"));
        });

        run("12 handles are independent", () -> {
            try (HtmlSanitizer a = new HtmlSanitizer(); HtmlSanitizer b = new HtmlSanitizer()) {
                a.allowedTags().add("only-in-a");
                assertTrue("a knows the tag", a.allowedTags().contains("only-in-a"));
                assertTrue("b does not", !b.allowedTags().contains("only-in-a"));
            }
        });

        // ---- extras that exercise the remaining callback shapes ----

        check("on_removing_attribute sees the attribute", s -> {
            List<String> seen = new ArrayList<>();
            s.onRemovingAttribute((elem, attr, reason) -> {
                seen.add(elem.name() + "/" + attr.name() + "/" + attr.value());
                return false;
            });
            assertEquals("<div>x</div>", s.sanitize("<div onclick=\"alert(1)\">x</div>"));
            assertTrue("saw div/onclick/alert(1) in " + seen,
                    seen.contains("div/onclick/alert(1)"));
        });

        check("on_removing_comment cancels", s -> {
            s.onRemovingComment(node -> true);
            assertEquals("<div>a<!-- keep -->b</div>", s.sanitize("<div>a<!-- keep -->b</div>"));
        });

        check("on_removing_style is four-arg", s -> {
            List<String> seen = new ArrayList<>();
            s.onRemovingStyle((elem, name, value, reason) -> {
                seen.add(name + "/" + value);
                return name.equals("-custom-thing");
            });
            String out = s.sanitize("<div style=\"-custom-thing: 3; color: red\">x</div>");
            assertTrue("kept -custom-thing, got " + out, out.contains("-custom-thing"));
            assertTrue("saw -custom-thing/3 in " + seen, seen.contains("-custom-thing/3"));
        });

        check("post_process_node visits", s -> {
            List<Integer> kinds = new ArrayList<>();
            s.onPostProcessNode(node -> kinds.add(node.kind()));
            s.sanitize("<div><span>a</span><span>b</span></div>");
            assertTrue("visited at least one node", !kinds.isEmpty());
        });

        check("node tree navigation", s -> {
            int[] captured = new int[2];
            s.onPostProcessDom(doc -> {
                captured[0] = doc.kind();
                captured[1] = doc.children().size();
            });
            s.sanitize("<div>a</div><p>b</p>");
            assertEquals(Native.NODE_DOCUMENT, captured[0]);
            assertTrue("document had >= 2 children, got " + captured[1], captured[1] >= 2);
        });

        check("abi version", s -> assertTrue("abi >= 1", s.abiVersion() >= 1));

        check("sanitize_document is wired", s ->
                assertEquals("<div>doc</div>",
                        s.sanitizeDocument("<div>doc<script>x</script></div>")));

        check("attribute set_value rewrites", s -> {
            s.onRemovingAttribute((elem, attr, reason) -> {
                if (attr.name().equals("onclick")) {
                    // Prove the setter reaches the DOM: rename the value and
                    // keep the attribute by cancelling the removal.
                    attr.setValue("safe");
                    return true;
                }
                return false;
            });
            assertEquals("<div onclick=\"safe\">x</div>",
                    s.sanitize("<div onclick=\"alert(1)\">x</div>"));
        });

        run("closed sanitizer rejects use", () -> {
            HtmlSanitizer s = new HtmlSanitizer();
            s.close();
            try {
                s.sanitize("<div>x</div>");
                throw new AssertionError("expected IllegalStateException");
            } catch (IllegalStateException expected) {
                // exactly right
            }
        });

        // ---- report ----
        System.out.println();
        if (failures.isEmpty()) {
            System.out.println("PASS — " + passed + " checks");
            System.exit(0);
        }
        System.out.println("FAIL — " + failures.size() + " of "
                + (passed + failures.size()) + " checks failed:");
        for (String f : failures) System.out.println("  " + f);
        System.exit(1);
    }

    /** Run one check against a fresh sanitizer, always closing it. */
    private static void check(String name, Consumer<HtmlSanitizer> body) {
        run(name, () -> {
            try (HtmlSanitizer s = new HtmlSanitizer()) {
                body.accept(s);
            }
        });
    }

    private static void run(String name, Runnable body) {
        try {
            body.run();
            passed++;
            System.out.println("  ok   " + name);
        } catch (Throwable t) {
            failures.add(name + ": " + t);
            System.out.println("  FAIL " + name + ": " + t);
        }
    }

    private static void assertEquals(Object expected, Object actual) {
        if (!String.valueOf(expected).equals(String.valueOf(actual))) {
            throw new AssertionError("expected <" + expected + "> but was <" + actual + ">");
        }
    }

    private static void assertTrue(String what, boolean cond) {
        if (!cond) throw new AssertionError("expected " + what);
    }

    private ConformanceTest() {
    }
}
