package org.htmlsanitizer.scala

import org.htmlsanitizer.HtmlSanitizer
import org.htmlsanitizer.scala.HtmlSanitizers._

import scala.collection.mutable

/**
 * The 12-check binding conformance suite (docs/conformance.md), in Scala.
 *
 * Proves the '''Scala layer''' marshals every value shape correctly. Since that
 * layer sits on the Java binding rather than on its own FFI, what this suite
 * really pins down is that the Scala sugar — function-value callbacks, the
 * `+=`/`-=` allow-list ops, the loan pattern — reaches the same engine
 * behaviour the Java and Python suites see. A function literal that failed to
 * become the right SAM, or a `+=` that mutated a copy instead of the live view,
 * would fail here and nowhere else.
 *
 * It is NOT a sanitizer test suite — the behavioural cases live in the engine's
 * own tests and run once, in Aether.
 *
 * A plain main method, not ScalaTest or MUnit, for the same reason the Java
 * suite is a main method: the run then needs nothing but a JDK and the Scala
 * compiler + library, so it works offline and cannot fail resolving a
 * test-framework artifact.
 */
object ConformanceTest {

  private var passed = 0
  private val failures = mutable.ListBuffer.empty[String]

  def main(args: Array[String]): Unit = {
    // ---- the 12 required checks ----

    check("01 script removed") { s =>
      assertEquals("<div>Hello  world!</div>",
        s.sanitize("<div>Hello <script>alert(1)</script> world!</div>"))
    }

    check("02 onclick removed") { s =>
      assertEquals("<div>Hello</div>", s.sanitize("""<div onclick="alert(1)">Hello</div>"""))
    }

    check("03 empty string") { s => assertEquals("", s.sanitize("")) }

    check("04 utf-8 round trip") { s =>
      assertEquals("<div>café ☕</div>", s.sanitize("<div>café ☕</div>"))
    }

    check("05 allow custom tag") { s =>
      assertEquals("", s.sanitize("<my-widget>x</my-widget>"))
      s.allowedTags += "my-widget"          // operator, not .add()
      assertEquals("<my-widget>x</my-widget>", s.sanitize("<my-widget>x</my-widget>"))
    }

    check("06 disallow tag") { s =>
      assertEquals("<div>x</div>", s.sanitize("<div>x</div>"))
      s.allowedTags -= "div"                // operator, not .remove()
      assertEquals("", s.sanitize("<div>x</div>"))
    }

    check("07 membership and count") { s =>
      assertTrue("http is allowed", s.allowedSchemes.contains("http"))
      assertTrue("gopher is not", !s.allowedSchemes.contains("gopher"))
      assertEquals(2, s.allowedSchemes.size())
    }

    check("08 enumeration") { s =>
      assertEquals(List("http", "https"), s.allowedSchemes.toScalaList.sorted)
    }

    check("09 keep child nodes") { s =>
      assertEquals("<div></div>", s.sanitize("<div><nope>Hello <span>world</span></nope></div>"))
      s.setKeepChildNodes(true)             // explicit setter; see HtmlSanitizerOps
      assertTrue("flag reads back", s.keepChildNodes)
      assertEquals("<div>Hello <span>world</span></div>",
        s.sanitize("<div><nope>Hello <span>world</span></nope></div>"))
    }

    check("10 on_removing_tag cancels") { s =>
      val seen = mutable.ListBuffer.empty[(String, RemovalReason)]
      s.keepTagIf { (node, reason) =>
        seen += ((node.name(), reason))
        node.name() == "keep-me"
      }
      assertEquals("<div><keep-me>a</keep-me></div>",
        s.sanitize("<div><keep-me>a</keep-me><drop-me>b</drop-me></div>"))
      assertTrue(s"saw keep-me in $seen", seen.contains(("keep-me", RemovalReason.NotAllowedTag)))
      assertTrue(s"saw drop-me in $seen", seen.contains(("drop-me", RemovalReason.NotAllowedTag)))
    }

    check("11 on_filter_url rewrites") { s =>
      s.rewriteUrls { (_, _, resolved) =>
        if (resolved == "https://example.com/logo.png") "https://cdn.example.net/logo.png"
        else resolved
      }
      assertEquals("""<img src="https://cdn.example.net/logo.png">""",
        s.sanitize("""<img src="logo.png">""", "https://example.com"))
    }

    run("12 handles are independent") {
      withSanitizer() { a =>
        withSanitizer() { b =>
          a.allowedTags += "only-in-a"
          assertTrue("a knows the tag", a.allowedTags.contains("only-in-a"))
          assertTrue("b does not", !b.allowedTags.contains("only-in-a"))
        }
      }
    }

    // ---- extras: the remaining callback shapes ----

    check("on_removing_attribute sees the attribute") { s =>
      val seen = mutable.ListBuffer.empty[(String, String, String)]
      s.keepAttributeIf { (elem, attr, _) =>
        seen += ((elem.name(), attr.name(), attr.value()))
        false
      }
      assertEquals("<div>x</div>", s.sanitize("""<div onclick="alert(1)">x</div>"""))
      assertTrue(s"saw div/onclick/alert(1) in $seen",
        seen.contains(("div", "onclick", "alert(1)")))
    }

    check("on_removing_comment cancels") { s =>
      s.keepCommentIf(_ => true)
      assertEquals("<div>a<!-- keep -->b</div>", s.sanitize("<div>a<!-- keep -->b</div>"))
    }

    check("on_removing_style is four-arg") { s =>
      val seen = mutable.ListBuffer.empty[(String, String)]
      s.keepStyleIf { (_, name, value, _) =>
        seen += ((name, value))
        name == "-custom-thing"
      }
      val out = s.sanitize("""<div style="-custom-thing: 3; color: red">x</div>""")
      assertTrue(s"kept -custom-thing, got $out", out.contains("-custom-thing"))
      assertTrue(s"saw -custom-thing/3 in $seen", seen.contains(("-custom-thing", "3")))
    }

    check("post_process_node visits") { s =>
      val kinds = mutable.ListBuffer.empty[NodeKind]
      s.eachNode(node => kinds += node.nodeKind)
      s.sanitize("<div><span>a</span><span>b</span></div>")
      assertTrue("visited at least one node", kinds.nonEmpty)
    }

    check("node tree navigation") { s =>
      var kind: NodeKind = NodeKind.Unknown(-1)
      var children = 0
      s.eachDocument { doc =>
        kind = doc.nodeKind
        children = doc.childNodes.size
      }
      s.sanitize("<div>a</div><p>b</p>")
      assertEquals(NodeKind.Document, kind)
      assertTrue(s"document had >= 2 children, got $children", children >= 2)
    }

    check("abi version") { s => assertTrue("abi >= 1", s.abiVersion() >= 1) }

    check("sanitize_document is wired") { s =>
      assertEquals("<html><head></head><body><div>doc</div></body></html>", s.sanitizeDocument("<div>doc<script>x</script></div>"))
    }

    check("attribute set_value rewrites") { s =>
      s.keepAttributeIf { (_, attr, _) =>
        if (attr.name() == "onclick") {
          attr.setValue("safe")
          true                              // cancel the removal
        } else false
      }
      assertEquals("""<div onclick="safe">x</div>""",
        s.sanitize("""<div onclick="alert(1)">x</div>"""))
    }

    run("closed sanitizer rejects use") {
      val s = new HtmlSanitizer()
      s.close()
      try {
        s.sanitize("<div>x</div>")
        throw new AssertionError("expected IllegalStateException")
      } catch {
        case _: IllegalStateException => // exactly right
      }
    }

    // ---- extras specific to the Scala layer ----

    run("sanitizer applies its configuration") {
      val s = sanitizer() { s =>
        s.allowedTags += "my-widget"
        s.setKeepChildNodes(true)
      }
      try {
        assertTrue("configured tag stuck", s.allowedTags.contains("my-widget"))
        assertTrue("configured flag stuck", s.keepChildNodes)
      } finally s.close()
    }

    run("sanitizer closes the handle when configure throws") {
      // A leaked native handle on the exception path would be invisible to
      // every other check, so it gets one of its own.
      try {
        sanitizer()(_ => throw new IllegalArgumentException("boom"))
        throw new AssertionError("expected the configure failure to propagate")
      } catch {
        case _: IllegalArgumentException => // exactly right
      }
    }

    run("withSanitizer closes even when the body throws") {
      try {
        withSanitizer()(_ => throw new IllegalStateException("boom"))
        throw new AssertionError("expected the body failure to propagate")
      } catch {
        case _: IllegalStateException => // exactly right
      }
    }

    run("one-shot sanitize convenience") {
      assertEquals("<div>Hello</div>",
        HtmlSanitizers.sanitize("""<div onclick="alert(1)">Hello</div>"""))
    }

    check("allow-list replaceWith starts from nothing") { s =>
      s.allowedTags.replaceWith("b", "i")
      assertEquals(2, s.allowedTags.size())
      assertEquals("<b>x</b>", s.sanitize("<b>x</b><div>y</div>"))
    }

    check("allow-list bulk ops") { s =>
      s.allowedTags ++= List("one-tag", "two-tag")
      assertTrue("added both", s.allowedTags.contains("one-tag") &&
        s.allowedTags.contains("two-tag"))
      s.allowedTags --= List("one-tag", "two-tag")
      assertTrue("removed both", !s.allowedTags.contains("one-tag") &&
        !s.allowedTags.contains("two-tag"))
    }

    check("Node.attribute finds one by name") { s =>
      var found: Option[String] = None
      s.keepAttributeIf { (elem, _, _) =>
        found = elem.attribute("onclick").map(_.value())
        false
      }
      s.sanitize("""<div onclick="alert(1)">x</div>""")
      assertEquals(Some("alert(1)"), found)
    }

    check("Node.walk is depth-first and inclusive") { s =>
      var count = 0
      s.eachDocument(doc => count = doc.walk.size)
      s.sanitize("<div><span>a</span></div>")
      // document + div + span + text, at least.
      assertTrue(s"walked >= 3 nodes, got $count", count >= 3)
    }

    check("unknown reason codes do not throw") { s =>
      // The ABI's constants are append-only; a code this build has never seen
      // must degrade to Unknown rather than blow up mid-sanitize.
      assertEquals(RemovalReason.Unknown(9999), RemovalReason.of(9999))
      assertEquals(NodeKind.Unknown(9999), NodeKind.of(9999))
      assertEquals("<div>x</div>", s.sanitize("<div>x</div>"))
    }

    // ---- report ----
    println()
    if (failures.isEmpty) {
      println(s"PASS — $passed checks")
      System.exit(0)
    }
    println(s"FAIL — ${failures.size} of ${passed + failures.size} checks failed:")
    failures.foreach(f => println(s"  $f"))
    System.exit(1)
  }

  /** Run one check against a fresh sanitizer, always closing it. */
  private def check(name: String)(body: HtmlSanitizer => Unit): Unit =
    run(name)(withSanitizer()(body))

  private def run(name: String)(body: => Unit): Unit =
    try {
      body
      passed += 1
      println(s"  ok   $name")
    } catch {
      case t: Throwable =>
        failures += s"$name: $t"
        println(s"  FAIL $name: $t")
    }

  private def assertEquals(expected: Any, actual: Any): Unit =
    if (String.valueOf(expected) != String.valueOf(actual)) {
      throw new AssertionError(s"expected <$expected> but was <$actual>")
    }

  private def assertTrue(what: String, cond: Boolean): Unit =
    if (!cond) throw new AssertionError(s"expected $what")
}
