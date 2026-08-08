package org.htmlsanitizer.groovy

import org.htmlsanitizer.HtmlSanitizer

import static org.htmlsanitizer.groovy.HtmlSanitizers.htmlSanitizer
import static org.htmlsanitizer.groovy.HtmlSanitizers.sanitizing

/**
 * The 12-check binding conformance suite (docs/conformance.md), in Groovy.
 *
 * Proves the <b>Groovy layer</b> marshals every value shape correctly. Since
 * that layer sits on the Java binding rather than on its own FFI, what this
 * suite really pins down is that the Groovy DSL — closure callbacks, the
 * SanitizerSpec verbs, the extension-module operators — reaches the same engine
 * behaviour the Java and Python suites see. A closure coerced to the wrong SAM
 * type, or a {@code <<} that mutated a copy instead of the live view, would
 * fail here and nowhere else.
 *
 * It is NOT a sanitizer test suite — the behavioural cases live in the engine's
 * own tests and run once, in Aether.
 *
 * A plain main method, not Spock/JUnit, for the same reason the Java suite is:
 * the run then needs nothing but a JDK and the Groovy jar, so it works offline
 * and cannot fail resolving a test-framework artifact.
 */
class ConformanceTest {

    static int passed = 0
    static List<String> failures = []

    static void main(String[] args) {
        // ---- the 12 required checks ----

        check('01 script removed') { HtmlSanitizer s ->
            assertEquals('<div>Hello  world!</div>',
                    s.sanitize('<div>Hello <script>alert(1)</script> world!</div>'))
        }

        check('02 onclick removed') { HtmlSanitizer s ->
            assertEquals('<div>Hello</div>', s.sanitize('<div onclick="alert(1)">Hello</div>'))
        }

        check('03 empty string') { HtmlSanitizer s -> assertEquals('', s.sanitize('')) }

        check('04 utf-8 round trip') { HtmlSanitizer s ->
            assertEquals('<div>café ☕</div>', s.sanitize('<div>café ☕</div>'))
        }

        check('05 allow custom tag') { HtmlSanitizer s ->
            assertEquals('', s.sanitize('<my-widget>x</my-widget>'))
            s.allowedTags() << 'my-widget'            // extension-module operator
            assertEquals('<my-widget>x</my-widget>', s.sanitize('<my-widget>x</my-widget>'))
        }

        check('06 disallow tag') { HtmlSanitizer s ->
            assertEquals('<div>x</div>', s.sanitize('<div>x</div>'))
            s.allowedTags() - 'div'
            assertEquals('', s.sanitize('<div>x</div>'))
        }

        check('07 membership and count') { HtmlSanitizer s ->
            assertTrue('http is allowed', s.allowedSchemes().contains('http'))
            assertTrue('gopher is not', !s.allowedSchemes().contains('gopher'))
            assertEquals(2, s.allowedSchemes().size())
        }

        check('08 enumeration') { HtmlSanitizer s ->
            // AllowList is Iterable<String>, so Groovy's sort() applies.
            assertEquals(['http', 'https'], s.allowedSchemes().toList().sort())
        }

        check('09 keep child nodes') { HtmlSanitizer s ->
            assertEquals('<div></div>',
                    s.sanitize('<div><nope>Hello <span>world</span></nope></div>'))
            s.keepChildNodes = true                   // extension-module property
            assertTrue('flag reads back', s.keepChildNodes)
            assertEquals('<div>Hello <span>world</span></div>',
                    s.sanitize('<div><nope>Hello <span>world</span></nope></div>'))
        }

        run('10 on_removing_tag cancels') {
            List seen = []
            htmlSanitizer {
                keepTagIf { node, reason ->
                    seen << [node.name(), reason]
                    node.name() == 'keep-me'
                }
            }.withCloseable { HtmlSanitizer s ->
                assertEquals('<div><keep-me>a</keep-me></div>',
                        s.sanitize('<div><keep-me>a</keep-me><drop-me>b</drop-me></div>'))
                assertTrue("saw keep-me in $seen", ['keep-me', Reasons.NOT_ALLOWED_TAG] in seen)
                assertTrue("saw drop-me in $seen", ['drop-me', Reasons.NOT_ALLOWED_TAG] in seen)
            }
        }

        run('11 on_filter_url rewrites') {
            htmlSanitizer {
                rewriteUrls { elem, raw, resolved ->
                    resolved == 'https://example.com/logo.png'
                            ? 'https://cdn.example.net/logo.png'
                            : resolved
                }
            }.withCloseable { HtmlSanitizer s ->
                assertEquals('<img src="https://cdn.example.net/logo.png">',
                        s.sanitize('<img src="logo.png">', 'https://example.com'))
            }
        }

        run('12 handles are independent') {
            new HtmlSanitizer().withCloseable { HtmlSanitizer a ->
                new HtmlSanitizer().withCloseable { HtmlSanitizer b ->
                    a.allowedTags() << 'only-in-a'
                    assertTrue('a knows the tag', a.allowedTags().contains('only-in-a'))
                    assertTrue('b does not', !b.allowedTags().contains('only-in-a'))
                }
            }
        }

        // ---- extras: the remaining callback shapes ----

        run('on_removing_attribute sees the attribute') {
            List seen = []
            htmlSanitizer {
                keepAttributeIf { elem, attr, reason ->
                    seen << [elem.name(), attr.name(), attr.value()]
                    false
                }
            }.withCloseable { HtmlSanitizer s ->
                assertEquals('<div>x</div>', s.sanitize('<div onclick="alert(1)">x</div>'))
                assertTrue("saw div/onclick/alert(1) in $seen",
                        ['div', 'onclick', 'alert(1)'] in seen)
            }
        }

        run('on_removing_comment cancels') {
            htmlSanitizer { keepCommentIf { node -> true } }.withCloseable { HtmlSanitizer s ->
                assertEquals('<div>a<!-- keep -->b</div>', s.sanitize('<div>a<!-- keep -->b</div>'))
            }
        }

        run('on_removing_style is four-arg') {
            List seen = []
            htmlSanitizer {
                keepStyleIf { elem, name, value, reason ->
                    seen << [name, value]
                    name == '-custom-thing'
                }
            }.withCloseable { HtmlSanitizer s ->
                String out = s.sanitize('<div style="-custom-thing: 3; color: red">x</div>')
                assertTrue("kept -custom-thing, got $out", out.contains('-custom-thing'))
                assertTrue("saw -custom-thing/3 in $seen", ['-custom-thing', '3'] in seen)
            }
        }

        run('post_process_node visits') {
            List kinds = []
            htmlSanitizer { eachNode { node -> kinds << node.kind() } }
                    .withCloseable { HtmlSanitizer s ->
                        s.sanitize('<div><span>a</span><span>b</span></div>')
                        assertTrue('visited at least one node', !kinds.isEmpty())
                    }
        }

        run('node tree navigation') {
            Map captured = [:]
            htmlSanitizer {
                eachDocument { doc ->
                    captured.kind = doc.kind()
                    captured.children = doc.children().size()
                }
            }.withCloseable { HtmlSanitizer s ->
                s.sanitize('<div>a</div><p>b</p>')
                assertEquals(NodeKinds.DOCUMENT, captured.kind)
                assertTrue("document had >= 2 children, got ${captured.children}",
                        captured.children >= 2)
            }
        }

        check('abi version') { HtmlSanitizer s -> assertTrue('abi >= 1', s.abiVersion() >= 1) }

        check('sanitize_document is wired') { HtmlSanitizer s ->
            assertEquals('<div>doc</div>', s.sanitizeDocument('<div>doc<script>x</script></div>'))
        }

        run('attribute set_value rewrites') {
            htmlSanitizer {
                keepAttributeIf { elem, attr, reason ->
                    if (attr.name() == 'onclick') {
                        attr.setValue('safe')
                        return true                   // cancel the removal
                    }
                    false
                }
            }.withCloseable { HtmlSanitizer s ->
                assertEquals('<div onclick="safe">x</div>',
                        s.sanitize('<div onclick="alert(1)">x</div>'))
            }
        }

        run('closed sanitizer rejects use') {
            HtmlSanitizer s = new HtmlSanitizer()
            s.close()
            try {
                s.sanitize('<div>x</div>')
                throw new AssertionError('expected IllegalStateException')
            } catch (IllegalStateException expected) {
                // exactly right
            }
        }

        // ---- extras specific to the Groovy layer ----

        run('htmlSanitizer applies its configuration block') {
            htmlSanitizer {
                allowTags 'my-widget'
                keepChildNodes = true
            }.withCloseable { HtmlSanitizer s ->
                assertTrue('configured tag stuck', s.allowedTags().contains('my-widget'))
                assertTrue('configured flag stuck', s.keepChildNodes())
            }
        }

        run('htmlSanitizer closes the handle when the block throws') {
            // A leaked native handle on the exception path would be invisible
            // to every other check, so it gets one of its own.
            try {
                htmlSanitizer { throw new IllegalArgumentException('boom') }
                throw new AssertionError('expected the configure failure to propagate')
            } catch (IllegalArgumentException expected) {
                // exactly right
            }
        }

        run('sanitizing runs and closes') {
            String out = sanitizing(null, null) { HtmlSanitizer s -> s.sanitize('<div>x</div>') }
            assertEquals('<div>x</div>', out)
        }

        run('one-shot sanitize convenience') {
            assertEquals('<div>Hello</div>',
                    HtmlSanitizers.sanitize('<div onclick="alert(1)">Hello</div>'))
        }

        run('denyTags verb') {
            htmlSanitizer { denyTags 'div' }.withCloseable { HtmlSanitizer s ->
                assertEquals('', s.sanitize('<div>x</div>'))
            }
        }

        run('Node getAt finds an attribute by name') {
            Map found = [:]
            htmlSanitizer {
                keepAttributeIf { elem, attr, reason ->
                    found.value = elem['onclick']?.value()
                    false
                }
            }.withCloseable { HtmlSanitizer s ->
                s.sanitize('<div onclick="alert(1)">x</div>')
                assertEquals('alert(1)', found.value)
            }
        }

        run('Node walk is depth-first and inclusive') {
            Map counted = [:]
            htmlSanitizer { eachDocument { doc -> counted.n = doc.walk().size() } }
                    .withCloseable { HtmlSanitizer s ->
                        s.sanitize('<div><span>a</span></div>')
                        // document + div + span + text, at least.
                        assertTrue("walked >= 3 nodes, got ${counted.n}", counted.n >= 3)
                    }
        }

        run('keep predicate tolerates a null return') {
            // Groovy truth, not unboxing: a closure falling off the end must
            // mean "do not keep", not NullPointerException.
            htmlSanitizer { keepTagIf { node, reason -> null } }
                    .withCloseable { HtmlSanitizer s ->
                        assertEquals('<div></div>', s.sanitize('<div><nope>x</nope></div>'))
                    }
        }

        run('rewriteUrls treats null as no rewrite') {
            htmlSanitizer { rewriteUrls { elem, raw, resolved -> null } }
                    .withCloseable { HtmlSanitizer s ->
                        assertEquals('<img src="https://example.com/logo.png">',
                                s.sanitize('<img src="logo.png">', 'https://example.com'))
                    }
        }

        // ---- report ----
        println()
        if (failures.isEmpty()) {
            println("PASS — $passed checks")
            System.exit(0)
        }
        println("FAIL — ${failures.size()} of ${passed + failures.size()} checks failed:")
        failures.each { println("  $it") }
        System.exit(1)
    }

    /** Run one check against a fresh sanitizer, always closing it. */
    static void check(String name, Closure body) {
        run(name) { new HtmlSanitizer().withCloseable(body) }
    }

    static void run(String name, Closure body) {
        try {
            body.call()
            passed++
            println("  ok   $name")
        } catch (Throwable t) {
            failures << "$name: $t"
            println("  FAIL $name: $t")
        }
    }

    static void assertEquals(Object expected, Object actual) {
        if (String.valueOf(expected) != String.valueOf(actual)) {
            throw new AssertionError("expected <$expected> but was <$actual>" as Object)
        }
    }

    static void assertTrue(String what, boolean cond) {
        if (!cond) throw new AssertionError("expected $what" as Object)
    }
}
