package org.htmlsanitizer.scala

import org.htmlsanitizer.{AllowList, Attribute, HtmlSanitizer, Native, Node}

import scala.jdk.CollectionConverters._

/**
 * Idiomatic Scala over the Java binding.
 *
 * There is '''no second FFI here'''. The one JVM binding to the shared Aether
 * sanitizer core is `java/src/main/java/org/htmlsanitizer` (FFM / Panama), and
 * everything in this file is ordinary Scala/Java interop on top of those
 * classes. A Scala-specific FFI would be a second copy of the ABI's marshalling
 * and ownership rules to keep in step with `core/embed.ae`, and the first thing
 * to drift.
 *
 * What Scala adds, and all it adds:
 *
 *   - [[HtmlSanitizers.using]] — loan-pattern bracketing, so the native handle
 *     is always released (Scala has no `try-with-resources`, and `Using` is
 *     2.13+, so this works on 2.12 too).
 *   - `on*` helpers taking ordinary Scala function values, so no explicit SAM
 *     construction is needed on 2.12.
 *   - [[AllowListOps]] — `+=`, `-=`, `contains`, `toSet` on the six live policy
 *     views.
 *   - [[RemovalReason]] and [[NodeKind]] as sealed ADTs over the ABI's ints.
 *
 * Targets '''Scala 2.13 and Scala 3''' from one source: no `enum`, no `given`,
 * no `extension` — an implicit class and a sealed ADT compile identically under
 * both. (`scala.jdk.CollectionConverters` and `IterableOnce` are 2.13+; on 2.12
 * they would need `scala-collection-compat`, which is a dependency this layer
 * deliberately does not take.)
 *
 * Not thread-safe, for the same reason the Java class is not: the sanitizer core calls
 * hooks re-entrantly during `sanitize`.
 */
object HtmlSanitizers {

  /**
   * Create a sanitizer, hand it to `body`, and close it — whatever happens.
   *
   * The loan pattern rather than a returned resource, because the thing being
   * managed is a native handle: leaking one leaks sanitizer core memory, and Scala has
   * no `try-with-resources` to fall back on.
   *
   * Deliberately NOT called `using`: that is a keyword in Scala 3, where
   * `using()(body)` parses as a using-clause and fails to compile. `withSanitizer`
   * reads the same and works on both 2.13 and 3.
   *
   * @param nativeLibPath an explicit sanitizer core path, or `None` for the usual
   *                      `$HTMLSANITIZER_LIB` / bundled / loader-path search
   */
  def withSanitizer[A](nativeLibPath: Option[String] = None)(body: HtmlSanitizer => A): A = {
    val s = new HtmlSanitizer(nativeLibPath.orNull)
    try body(s)
    finally s.close()
  }

  /**
   * Create a sanitizer, apply `configure`, and return it still open.
   *
   * The caller owns the result and must `close()` it. If `configure` throws,
   * the half-built sanitizer is closed rather than leaked — it owns a native
   * handle, and letting that escape on an exception path is exactly what this
   * wrapper should prevent.
   */
  def sanitizer(nativeLibPath: Option[String] = None)
               (configure: HtmlSanitizer => Unit = _ => ()): HtmlSanitizer = {
    val s = new HtmlSanitizer(nativeLibPath.orNull)
    try {
      configure(s)
      s
    } catch {
      case t: Throwable =>
        s.close()
        throw t
    }
  }

  /** Sanitize one fragment with the secure defaults, closing immediately. */
  def sanitize(html: String, baseUrl: String = ""): String =
    withSanitizer()(_.sanitize(html, baseUrl))

  // ---- syntax ----

  /**
   * Extension methods on the Java sanitizer.
   *
   * An implicit class rather than Scala 3 `extension`, so this source compiles
   * unchanged on 2.12, 2.13 and 3.
   */
  implicit class HtmlSanitizerOps(private val s: HtmlSanitizer) extends AnyVal {

    // ---- flags ----
    //
    // Readers are Scala-style no-paren accessors. The WRITERS are named
    // `setX` rather than spelled `x_=`: assignment syntax (`s.keepChildNodes =
    // true`) does not work through an implicit/extension class — Scala 3
    // rejects it as "Reassignment to val <none>", because there is no real
    // field to assign. Naming them honestly is better than shipping a form
    // that only looks like it works.

    def keepChildNodes: Boolean = s.keepChildNodes()

    def setKeepChildNodes(on: Boolean): HtmlSanitizer = s.keepChildNodes(on)

    def allowDataAttributes: Boolean = s.allowDataAttributes()

    def setAllowDataAttributes(on: Boolean): HtmlSanitizer = s.allowDataAttributes(on)

    // ---- the six live policy views ----

    def allowedTags: AllowList = s.allowedTags()

    def allowedAttributes: AllowList = s.allowedAttributes()

    def allowedCssProperties: AllowList = s.allowedCssProperties()

    def allowedSchemes: AllowList = s.allowedSchemes()

    def allowedClasses: AllowList = s.allowedClasses()

    def uriAttributes: AllowList = s.uriAttributes()

    // ---- callbacks, as plain Scala functions ----
    //
    // Named keep*If rather than onRemoving*: the ABI's rule is "non-zero
    // CANCELS the removal", so a handler returning true KEEPS the thing. The
    // Java names describe the event, which reads as though returning true
    // would remove it — the opposite of the truth. These names state the
    // decision instead.
    //
    // Distinct names also sidestep overload ambiguity with the Java methods,
    // which take SAM types Scala 2.12 will not infer a function literal into.

    /** Returning true KEEPS the tag. */
    def keepTagIf(p: (Node, RemovalReason) => Boolean): HtmlSanitizer =
      s.onRemovingTag(new HtmlSanitizer.RemovingTagHandler {
        override def onRemovingTag(node: Node, reason: Int): Boolean =
          p(node, RemovalReason.of(reason))
      })

    /** Returning true KEEPS the attribute. */
    def keepAttributeIf(p: (Node, Attribute, RemovalReason) => Boolean): HtmlSanitizer =
      s.onRemovingAttribute(new HtmlSanitizer.RemovingAttributeHandler {
        override def onRemovingAttribute(elem: Node, attr: Attribute, reason: Int): Boolean =
          p(elem, attr, RemovalReason.of(reason))
      })

    /** Returning true KEEPS the CSS property. */
    def keepStyleIf(p: (Node, String, String, RemovalReason) => Boolean): HtmlSanitizer =
      s.onRemovingStyle(new HtmlSanitizer.RemovingStyleHandler {
        override def onRemovingStyle(elem: Node, name: String, value: String,
                                     reason: Int): Boolean =
          p(elem, name, value, RemovalReason.of(reason))
      })

    /** Returning true KEEPS the comment. */
    def keepCommentIf(p: Node => Boolean): HtmlSanitizer =
      s.onRemovingComment(new HtmlSanitizer.RemovingCommentHandler {
        override def onRemovingComment(node: Node): Boolean = p(node)
      })

    def eachNode(visit: Node => Unit): HtmlSanitizer =
      s.onPostProcessNode(new HtmlSanitizer.PostProcessHandler {
        override def onPostProcess(node: Node): Unit = visit(node)
      })

    def eachDocument(visit: Node => Unit): HtmlSanitizer =
      s.onPostProcessDom(new HtmlSanitizer.PostProcessHandler {
        override def onPostProcess(node: Node): Unit = visit(node)
      })

    /**
     * Rewrite a URL. Return the URL to use; an '''empty string drops''' the
     * attribute entirely.
     */
    def rewriteUrls(f: (Node, String, String) => String): HtmlSanitizer =
      s.onFilterUrl(new HtmlSanitizer.FilterUrlHandler {
        override def onFilterUrl(elem: Node, raw: String, resolved: String): String =
          f(elem, raw, resolved)
      })
  }

  /** Set-like syntax for the six live policy views. */
  implicit class AllowListOps(private val list: AllowList) extends AnyVal {

    /** Allow an entry. */
    def +=(item: String): AllowList = list.add(item)

    /** Allow several. */
    def ++=(items: IterableOnce[String]): AllowList = {
      items.iterator.foreach(list.add)
      list
    }

    /** Deny an entry that is currently allowed. */
    def -=(item: String): AllowList = list.remove(item)

    def --=(items: IterableOnce[String]): AllowList = {
      items.iterator.foreach(list.remove)
      list
    }

    /** Snapshot. Iteration order is unspecified; each entry appears once. */
    def toScalaSet: Set[String] = list.toList.asScala.toSet

    def toScalaList: List[String] = list.toList.asScala.toList

    /** Replace the whole list — the "start from nothing" move. */
    def replaceWith(items: String*): AllowList = {
      list.clear()
      items.foreach(list.add)
      list
    }
  }

  /** Navigation helpers on a borrowed DOM node. */
  implicit class NodeOps(private val node: Node) extends AnyVal {

    def nodeKind: NodeKind = NodeKind.of(node.kind())

    def childNodes: List[Node] = node.children().asScala.toList

    def attributeList: List[Attribute] = node.attributes().asScala.toList

    /** The attribute with this name, or `None`. */
    def attribute(name: String): Option[Attribute] =
      attributeList.find(_.name() == name)

    /**
     * Depth-first list of this node and its descendants.
     *
     * A strict `List`, not a lazy `LazyList`/`Stream`: the DOM is freed when
     * `sanitize` returns, so a lazy walk forced after the callback would
     * dereference freed memory.
     */
    def walk: List[Node] = {
      val out = List.newBuilder[Node]
      def go(n: Node): Unit = {
        out += n
        n.children().asScala.foreach(go)
      }
      go(node)
      out.result()
    }
  }
}

/**
 * Why the sanitizer core is about to remove something.
 *
 * A sealed ADT with an [[RemovalReason.Unknown]] fallback, so a newer sanitizer core
 * adding a reason cannot make this layer throw — the ABI's constants are
 * append-only, and a total match over a closed set would be a latent break.
 */
sealed abstract class RemovalReason(val code: Int) extends Product with Serializable

object RemovalReason {
  case object NotAllowedTag extends RemovalReason(Native.REASON_NOT_ALLOWED_TAG)
  case object NotAllowedAttribute extends RemovalReason(Native.REASON_NOT_ALLOWED_ATTRIBUTE)
  case object NotAllowedStyle extends RemovalReason(Native.REASON_NOT_ALLOWED_STYLE)
  case object NotAllowedUrlValue extends RemovalReason(Native.REASON_NOT_ALLOWED_URL_VALUE)
  case object NotAllowedValue extends RemovalReason(Native.REASON_NOT_ALLOWED_VALUE)
  case object NotAllowedCssClass extends RemovalReason(Native.REASON_NOT_ALLOWED_CSS_CLASS)
  case object ClassAttributeEmpty extends RemovalReason(Native.REASON_CLASS_ATTRIBUTE_EMPTY)
  case object StyleAttributeEmpty extends RemovalReason(Native.REASON_STYLE_ATTRIBUTE_EMPTY)

  /** An code this build does not know — a newer sanitizer core, not an error. */
  final case class Unknown(override val code: Int) extends RemovalReason(code)

  private val known: List[RemovalReason] = List(
    NotAllowedTag, NotAllowedAttribute, NotAllowedStyle, NotAllowedUrlValue,
    NotAllowedValue, NotAllowedCssClass, ClassAttributeEmpty, StyleAttributeEmpty,
  )

  def of(code: Int): RemovalReason =
    known.find(_.code == code).getOrElse(Unknown(code))
}

/** 1=Document, 2=Element, 3=Text, 4=Comment. */
sealed abstract class NodeKind(val code: Int) extends Product with Serializable

object NodeKind {
  case object Document extends NodeKind(Native.NODE_DOCUMENT)
  case object Element extends NodeKind(Native.NODE_ELEMENT)
  case object Text extends NodeKind(Native.NODE_TEXT)
  case object Comment extends NodeKind(Native.NODE_COMMENT)
  final case class Unknown(override val code: Int) extends NodeKind(code)

  private val known: List[NodeKind] = List(Document, Element, Text, Comment)

  def of(code: Int): NodeKind = known.find(_.code == code).getOrElse(Unknown(code))
}
