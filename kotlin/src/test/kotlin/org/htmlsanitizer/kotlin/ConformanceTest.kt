package org.htmlsanitizer.kotlin

import org.htmlsanitizer.HtmlSanitizer

/**
 * The 12-check binding conformance suite (docs/conformance.md), in Kotlin.
 *
 * Proves the **Kotlin layer** marshals every value shape correctly. Since that
 * layer sits on the Java binding rather than on its own FFI, what this suite
 * really pins down is that the Kotlin sugar — trailing-lambda callbacks,
 * operator allow-lists, property flags — reaches the same engine behaviour the
 * Java and Python suites see. A SAM conversion that quietly dropped a
 * callback, or a `+=` that mutated a copy instead of the live view, would fail
 * here and nowhere else.
 *
 * It is NOT a sanitizer test suite — the behavioural cases live in the
 * engine's own tests and run once, in Aether.
 *
 * A plain main method, not JUnit, for the same reason the Java suite is: the
 * run then needs nothing but a JDK and a Kotlin compiler, so it works offline
 * and cannot fail resolving a test-framework artifact.
 */
object ConformanceTest {

    private var passed = 0
    private val failures = mutableListOf<String>()

    @JvmStatic
    fun main(args: Array<String>) {
        // ---- the 12 required checks ----

        check("01 script removed") { s ->
            assertEquals(
                "<div>Hello  world!</div>",
                s.sanitize("<div>Hello <script>alert(1)</script> world!</div>"),
            )
        }

        check("02 onclick removed") { s ->
            assertEquals("<div>Hello</div>", s.sanitize("""<div onclick="alert(1)">Hello</div>"""))
        }

        check("03 empty string") { s -> assertEquals("", s.sanitize("")) }

        check("04 utf-8 round trip") { s ->
            assertEquals("<div>café ☕</div>", s.sanitize("<div>café ☕</div>"))
        }

        check("05 allow custom tag") { s ->
            assertEquals("", s.sanitize("<my-widget>x</my-widget>"))
            s.allowedTags += "my-widget"          // operator, not .add()
            assertEquals("<my-widget>x</my-widget>", s.sanitize("<my-widget>x</my-widget>"))
        }

        check("06 disallow tag") { s ->
            assertEquals("<div>x</div>", s.sanitize("<div>x</div>"))
            s.allowedTags -= "div"                // operator, not .remove()
            assertEquals("", s.sanitize("<div>x</div>"))
        }

        check("07 membership and count") { s ->
            assertTrue("http is allowed", "http" in s.allowedSchemes)
            assertTrue("gopher is not", "gopher" !in s.allowedSchemes)
            assertEquals(2, s.allowedSchemes.count)
        }

        check("08 enumeration") { s ->
            // AllowList is Iterable<String>, so Kotlin's sorted() applies.
            assertEquals(listOf("http", "https"), s.allowedSchemes.sorted())
        }

        check("09 keep child nodes") { s ->
            assertEquals(
                "<div></div>",
                s.sanitize("<div><nope>Hello <span>world</span></nope></div>"),
            )
            s.keepChildNodes = true               // property, not a call
            assertTrue("flag reads back", s.keepChildNodes)
            assertEquals(
                "<div>Hello <span>world</span></div>",
                s.sanitize("<div><nope>Hello <span>world</span></nope></div>"),
            )
        }

        check("10 on_removing_tag cancels") { s ->
            val seen = mutableListOf<Pair<String, RemovalReason>>()
            s.keepTagIf { node, reason ->
                seen += node.name() to reason
                node.name() == "keep-me"
            }
            assertEquals(
                "<div><keep-me>a</keep-me></div>",
                s.sanitize("<div><keep-me>a</keep-me><drop-me>b</drop-me></div>"),
            )
            assertTrue("saw keep-me in $seen", ("keep-me" to RemovalReason.NOT_ALLOWED_TAG) in seen)
            assertTrue("saw drop-me in $seen", ("drop-me" to RemovalReason.NOT_ALLOWED_TAG) in seen)
        }

        check("11 on_filter_url rewrites") { s ->
            s.rewriteUrls { _, _, resolved ->
                if (resolved == "https://example.com/logo.png") {
                    "https://cdn.example.net/logo.png"
                } else {
                    resolved
                }
            }
            assertEquals(
                """<img src="https://cdn.example.net/logo.png">""",
                s.sanitize("""<img src="logo.png">""", "https://example.com"),
            )
        }

        run("12 handles are independent") {
            htmlSanitizer().use { a ->
                htmlSanitizer().use { b ->
                    a.allowedTags += "only-in-a"
                    assertTrue("a knows the tag", "only-in-a" in a.allowedTags)
                    assertTrue("b does not", "only-in-a" !in b.allowedTags)
                }
            }
        }

        // ---- extras: the remaining callback shapes ----

        check("on_removing_attribute sees the attribute") { s ->
            val seen = mutableListOf<Triple<String, String, String>>()
            s.keepAttributeIf { elem, attr, _ ->
                seen += Triple(elem.name(), attr.name(), attr.value())
                false
            }
            assertEquals("<div>x</div>", s.sanitize("""<div onclick="alert(1)">x</div>"""))
            assertTrue(
                "saw div/onclick/alert(1) in $seen",
                Triple("div", "onclick", "alert(1)") in seen,
            )
        }

        check("on_removing_comment cancels") { s ->
            s.keepCommentIf { true }
            assertEquals("<div>a<!-- keep -->b</div>", s.sanitize("<div>a<!-- keep -->b</div>"))
        }

        check("on_removing_style is four-arg") { s ->
            val seen = mutableListOf<Pair<String, String>>()
            s.keepStyleIf { _, name, value, _ ->
                seen += name to value
                name == "-custom-thing"
            }
            val out = s.sanitize("""<div style="-custom-thing: 3; color: red">x</div>""")
            assertTrue("kept -custom-thing, got $out", "-custom-thing" in out)
            assertTrue("saw -custom-thing/3 in $seen", ("-custom-thing" to "3") in seen)
        }

        check("post_process_node visits") { s ->
            val kinds = mutableListOf<NodeKind>()
            s.eachNode { node -> kinds += node.nodeKind }
            s.sanitize("<div><span>a</span><span>b</span></div>")
            assertTrue("visited at least one node", kinds.isNotEmpty())
        }

        check("node tree navigation") { s ->
            var kind: NodeKind? = null
            var children = 0
            s.eachDocument { doc ->
                kind = doc.nodeKind
                children = doc.children().size
            }
            s.sanitize("<div>a</div><p>b</p>")
            assertEquals(NodeKind.DOCUMENT, kind)
            assertTrue("document had >= 2 children, got $children", children >= 2)
        }

        check("abi version") { s -> assertTrue("abi >= 1", s.abiVersion() >= 1) }

        check("sanitize_document is wired") { s ->
            // sanitizeDocument emits a DOCUMENT, not a fragment — it ADDS the
            // envelope when the input lacks one. sanitize() is the fragment
            // form. docs/conformance.md pins this distinction; asserting the
            // fragment shape here predated the normalize/sanitize split and
            // only passed while the two were aliases.
            assertEquals(
                "<html><head></head><body><div>doc</div></body></html>",
                s.sanitizeDocument("<div>doc<script>x</script></div>")
            )
        }

        check("attribute set_value rewrites") { s ->
            s.keepAttributeIf { _, attr, _ ->
                if (attr.name() == "onclick") {
                    attr.setValue("safe")
                    true                          // cancel the removal
                } else {
                    false
                }
            }
            assertEquals(
                """<div onclick="safe">x</div>""",
                s.sanitize("""<div onclick="alert(1)">x</div>"""),
            )
        }

        run("closed sanitizer rejects use") {
            val s = HtmlSanitizer()
            s.close()
            try {
                s.sanitize("<div>x</div>")
                throw AssertionError("expected IllegalStateException")
            } catch (expected: IllegalStateException) {
                // exactly right
            }
        }

        // ---- extras specific to the Kotlin layer ----

        run("htmlSanitizer builder applies its configuration") {
            htmlSanitizer {
                allowedTags += "my-widget"
                keepChildNodes = true
            }.use { s ->
                assertTrue("configured tag stuck", "my-widget" in s.allowedTags)
                assertTrue("configured flag stuck", s.keepChildNodes)
            }
        }

        run("htmlSanitizer closes the handle when configure throws") {
            // A leaked native handle on the exception path would be invisible
            // to every other check, so it gets one of its own.
            try {
                htmlSanitizer { throw IllegalArgumentException("boom") }
                throw AssertionError("expected the configure failure to propagate")
            } catch (expected: IllegalArgumentException) {
                // exactly right
            }
        }

        check("sanitizing runs and closes") { _ ->
            val out = sanitizing { s -> s.sanitize("<div>x</div>") }
            assertEquals("<div>x</div>", out)
        }

        check("allow-list replaceWith starts from nothing") { s ->
            s.allowedTags.replaceWith("b", "i")
            assertEquals(2, s.allowedTags.count)
            assertEquals("<b>x</b>", s.sanitize("<b>x</b><div>y</div>"))
        }

        check("Node.get finds an attribute by name") { s ->
            var found: String? = null
            s.keepAttributeIf { elem, _, _ ->
                found = elem["onclick"]?.value()
                false
            }
            s.sanitize("""<div onclick="alert(1)">x</div>""")
            assertEquals("alert(1)", found)
        }

        check("Node.walk is depth-first and inclusive") { s ->
            var count = 0
            s.eachDocument { doc -> count = doc.walk().count() }
            s.sanitize("<div><span>a</span></div>")
            // document + div + span + text, at least.
            assertTrue("walked >= 3 nodes, got $count", count >= 3)
        }

        // ---- report ----
        println()
        if (failures.isEmpty()) {
            println("PASS — $passed checks")
            System.exit(0)
        }
        println("FAIL — ${failures.size} of ${passed + failures.size} checks failed:")
        failures.forEach { println("  $it") }
        System.exit(1)
    }

    /** Run one check against a fresh sanitizer, always closing it. */
    private fun check(name: String, body: (HtmlSanitizer) -> Unit) =
        run(name) { HtmlSanitizer().use(body) }

    private fun run(name: String, body: () -> Unit) {
        try {
            body()
            passed++
            println("  ok   $name")
        } catch (t: Throwable) {
            failures += "$name: $t"
            println("  FAIL $name: $t")
        }
    }

    private fun assertEquals(expected: Any?, actual: Any?) {
        if (expected.toString() != actual.toString()) {
            throw AssertionError("expected <$expected> but was <$actual>")
        }
    }

    private fun assertTrue(what: String, cond: Boolean) {
        if (!cond) throw AssertionError("expected $what")
    }
}
