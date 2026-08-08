(ns org.htmlsanitizer.core
  "Idiomatic Clojure over the Java binding.

  There is **no second FFI here**. The one JVM binding to the shared Aether
  engine is `java/src/main/java/org/htmlsanitizer` (FFM / Panama), and
  everything in this namespace is ordinary Clojure/Java interop on top of those
  classes. A Clojure-specific FFI would be a second copy of the ABI's
  marshalling and ownership rules to keep in step with `core/embed.ae`, and the
  first thing to drift.

  What Clojure adds, and all it adds:

    * `sanitizer` returns an `AutoCloseable`, so **`with-open` is the idiom** —
      no custom macro needed, and the native handle is always released.
    * plain functions over the Java methods, so they compose and thread
      (`->`, `doto`).
    * callbacks take ordinary Clojure fns; the SAM wrapping is done here once.
    * keyword removal reasons and node kinds instead of the ABI's bare ints.
    * `node->map` / `attr->map` for pulling a **borrowed** DOM node into an
      immutable snapshot that is safe to keep.

  Not thread-safe, for the same reason the Java class is not: the engine calls
  hooks re-entrantly during `sanitize`."
  ;; The handler interfaces are NESTED in HtmlSanitizer, so their binary names
  ;; are HtmlSanitizer$RemovingTagHandler and friends — that is the name
  ;; `import` and `reify` both need.
  (:import (org.htmlsanitizer AllowList Attribute HtmlSanitizer Native Node)
           (org.htmlsanitizer HtmlSanitizer$RemovingTagHandler
                              HtmlSanitizer$RemovingAttributeHandler
                              HtmlSanitizer$RemovingStyleHandler
                              HtmlSanitizer$RemovingCommentHandler
                              HtmlSanitizer$PostProcessHandler
                              HtmlSanitizer$FilterUrlHandler)))

(set! *warn-on-reflection* true)

;; ---- ABI constants as keywords -------------------------------------------
;;
;; Maps rather than a case expression, and with an explicit fallback, because
;; the ABI's constants are append-only: a newer engine may pass a code this
;; build has never seen, and that must not blow up mid-sanitize.

(def ^:private reason->kw
  {Native/REASON_NOT_ALLOWED_TAG        :not-allowed-tag
   Native/REASON_NOT_ALLOWED_ATTRIBUTE  :not-allowed-attribute
   Native/REASON_NOT_ALLOWED_STYLE      :not-allowed-style
   Native/REASON_NOT_ALLOWED_URL_VALUE  :not-allowed-url-value
   Native/REASON_NOT_ALLOWED_VALUE      :not-allowed-value
   Native/REASON_NOT_ALLOWED_CSS_CLASS  :not-allowed-css-class
   Native/REASON_CLASS_ATTRIBUTE_EMPTY  :class-attribute-empty
   Native/REASON_STYLE_ATTRIBUTE_EMPTY  :style-attribute-empty})

(def ^:private kind->kw
  {Native/NODE_DOCUMENT :document
   Native/NODE_ELEMENT  :element
   Native/NODE_TEXT     :text
   Native/NODE_COMMENT  :comment})

(defn removal-reason
  "The ABI removal-reason code as a keyword, or `:unknown` for a code this
  build does not know (a newer engine, not an error)."
  [code]
  (get reason->kw code :unknown))

(defn node-kind-of
  "An ABI node-kind code as a keyword: `:document`, `:element`, `:text`,
  `:comment`, or `:unknown`."
  [code]
  (get kind->kw code :unknown))

;; ---- lifecycle -----------------------------------------------------------

(defn sanitizer
  "Create a sanitizer with the secure defaults.

  Returns an `AutoCloseable`, so the idiom is `with-open` — which is exactly
  why no bespoke macro is offered here:

      (with-open [s (sanitizer)]
        (sanitize s \"<div onclick=\\\"evil()\\\">hi</div>\"))

  `lib-path` is an explicit engine path; omit it for the usual
  `$HTMLSANITIZER_LIB` / bundled / loader-path search."
  (^HtmlSanitizer [] (HtmlSanitizer.))
  (^HtmlSanitizer [lib-path] (HtmlSanitizer. lib-path)))

(defn close!
  "Release the native handle and the upcall stubs. `with-open` calls this for
  you; it is here for the rare case that owns a sanitizer explicitly."
  [^HtmlSanitizer s]
  (.close s))

(defn abi-version
  "The engine's ABI revision."
  [^HtmlSanitizer s]
  (.abiVersion s))

;; ---- the main entry points -----------------------------------------------

(defn sanitize
  "Sanitize an HTML fragment, optionally resolving relative URLs against
  `base-url`."
  ([^HtmlSanitizer s ^String html] (.sanitize s html))
  ([^HtmlSanitizer s ^String html ^String base-url] (.sanitize s html base-url)))

(defn sanitize-document
  "Sanitize a full HTML document."
  ([^HtmlSanitizer s ^String html] (.sanitizeDocument s html))
  ([^HtmlSanitizer s ^String html ^String base-url] (.sanitizeDocument s html base-url)))

(defn sanitize-once
  "Sanitize one fragment with the secure defaults, creating and closing a
  sanitizer around it. For the one-off case where a handle would be ceremony."
  ([html] (sanitize-once html ""))
  ([html base-url]
   (with-open [s (sanitizer)]
     (sanitize s html base-url))))

;; ---- flags ---------------------------------------------------------------
;;
;; Setters return the sanitizer so they thread with `->` and compose in `doto`.

(defn keep-child-nodes?
  "Are the children of a removed element kept rather than dropped?"
  [^HtmlSanitizer s]
  (.keepChildNodes s))

(defn keep-child-nodes!
  [^HtmlSanitizer s on]
  (.keepChildNodes s (boolean on)))

(defn allow-data-attributes?
  [^HtmlSanitizer s]
  (.allowDataAttributes s))

(defn allow-data-attributes!
  [^HtmlSanitizer s on]
  (.allowDataAttributes s (boolean on)))

;; ---- allow-lists ---------------------------------------------------------

(defn allow-list
  "One of the engine's six live policy views, by keyword: `:tags`,
  `:attributes`, `:css-properties`, `:schemes`, `:classes`, `:uri-attributes`.

  The result is a live view on the engine, not a copy — mutating it changes
  the policy immediately."
  ^AllowList [^HtmlSanitizer s which]
  (case which
    :tags           (.allowedTags s)
    :attributes     (.allowedAttributes s)
    :css-properties (.allowedCssProperties s)
    :schemes        (.allowedSchemes s)
    :classes        (.allowedClasses s)
    :uri-attributes (.uriAttributes s)
    (throw (IllegalArgumentException.
             (str "unknown allow-list " which
                  " (expected one of :tags :attributes :css-properties"
                  " :schemes :classes :uri-attributes)")))))

(defn allow!
  "Allow one or more entries on the `which` list. Returns the sanitizer, so it
  threads."
  [^HtmlSanitizer s which & items]
  (let [l (allow-list s which)]
    (doseq [i items] (.add l ^String i))
    s))

(defn disallow!
  "The deny direction — drop entries that are currently allowed. Returns the
  sanitizer."
  [^HtmlSanitizer s which & items]
  (let [l (allow-list s which)]
    (doseq [i items] (.remove l ^String i))
    s))

(defn allowed?
  "Is `item` on the `which` list?"
  [^HtmlSanitizer s which ^String item]
  (.contains (allow-list s which) item))

(defn allow-count
  "How many entries the `which` list holds, straight from the engine."
  [^HtmlSanitizer s which]
  (.size (allow-list s which)))

(defn allowed
  "Snapshot the `which` list as a Clojure set."
  [^HtmlSanitizer s which]
  (set (.toList (allow-list s which))))

(defn clear!
  "Empty the `which` list — the 'start from nothing' move for a strict policy.
  Returns the sanitizer."
  [^HtmlSanitizer s which]
  (.clear (allow-list s which))
  s)

(defn replace-allowed!
  "Clear the `which` list and set it to exactly `items`. Returns the sanitizer."
  [^HtmlSanitizer s which & items]
  (clear! s which)
  (apply allow! s which items))

;; ---- DOM helpers ---------------------------------------------------------
;;
;; Node and Attribute are BORROWED views: the DOM is freed when sanitize
;; returns, so a Node held past its callback is a dangling pointer. The
;; ->map fns exist so a callback can take an immutable snapshot that IS safe
;; to keep — which is the thing Clojure users will reach for by reflex.

(defn node-kind
  "This node's kind, as a keyword."
  [^Node n]
  (node-kind-of (.kind n)))

(defn node-name
  "Element tag name, lowercased by the parser; empty for non-elements."
  [^Node n]
  (.name n))

(defn node-value
  "Text/comment content; empty for elements and documents."
  [^Node n]
  (.value n))

(defn children
  "This node's child nodes, as a vector of borrowed `Node`s."
  [^Node n]
  (vec (.children n)))

(defn attributes
  "This node's attributes, as a vector of borrowed `Attribute`s."
  [^Node n]
  (vec (.attributes n)))

(defn attr-name [^Attribute a] (.name a))

(defn attr-value [^Attribute a] (.value a))

(defn set-attr-value!
  "Rewrite an attribute's value in place — e.g. to canonicalise a URL rather
  than let the attribute be removed."
  [^Attribute a ^String v]
  (.setValue a v)
  a)

(defn attribute
  "The attribute of `n` with this name, or nil."
  ^Attribute [^Node n ^String nm]
  (first (filter #(= nm (attr-name %)) (attributes n))))

(defn attr->map
  "An immutable snapshot of a borrowed attribute: `{:name .. :value ..}`."
  [^Attribute a]
  {:name (attr-name a) :value (attr-value a)})

(defn node->map
  "A recursive, immutable snapshot of a borrowed node:
  `{:kind .. :name .. :value .. :attributes [..] :children [..]}`.

  Safe to keep after the callback returns, which the `Node` itself is not."
  [^Node n]
  {:kind       (node-kind n)
   :name       (node-name n)
   :value      (node-value n)
   :attributes (mapv attr->map (attributes n))
   :children   (mapv node->map (children n))})

(defn walk
  "Depth-first seq of this node and its descendants, inclusive.

  Fully realised, not lazy: the DOM is freed when `sanitize` returns, so a lazy
  walk forced after the callback would dereference freed memory."
  [^Node n]
  (into [n] (mapcat walk (children n))))

;; ---- callbacks -----------------------------------------------------------
;;
;; Named keep-*-if! rather than on-removing-*: the ABI's rule is "non-zero
;; CANCELS the removal", so a handler returning true KEEPS the thing. Naming
;; them after the event would read as though true meant "remove it" — the
;; opposite of the truth.
;;
;; Every one returns the sanitizer, so they thread with `->` and stack in
;; `doto`. Passing nil clears the hook.
;;
;; Predicate results go through Clojure truthiness (`boolean`), so a fn
;; returning nil means "do not keep" rather than throwing on unboxing.

(defn keep-tag-if!
  "Install a hook run before a tag is removed. Returning logical true KEEPS the
  tag. `f` is called with `[node reason-keyword]`."
  [^HtmlSanitizer s f]
  (.onRemovingTag s (when f
                      (reify HtmlSanitizer$RemovingTagHandler
                        (onRemovingTag [_ node reason]
                          (boolean (f node (removal-reason reason)))))))
  s)

(defn keep-attribute-if!
  "Returning logical true KEEPS the attribute. `f` is called with
  `[element attribute reason-keyword]`."
  [^HtmlSanitizer s f]
  (.onRemovingAttribute s (when f
                            (reify HtmlSanitizer$RemovingAttributeHandler
                              (onRemovingAttribute [_ elem attr reason]
                                (boolean (f elem attr (removal-reason reason)))))))
  s)

(defn keep-style-if!
  "Returning logical true KEEPS the CSS property. `f` is called with
  `[element property-name value reason-keyword]`."
  [^HtmlSanitizer s f]
  (.onRemovingStyle s (when f
                        (reify HtmlSanitizer$RemovingStyleHandler
                          (onRemovingStyle [_ elem nm v reason]
                            (boolean (f elem nm v (removal-reason reason)))))))
  s)

(defn keep-comment-if!
  "Returning logical true KEEPS the comment. `f` is called with `[node]`."
  [^HtmlSanitizer s f]
  (.onRemovingComment s (when f
                          (reify HtmlSanitizer$RemovingCommentHandler
                            (onRemovingComment [_ node]
                              (boolean (f node))))))
  s)

(defn each-node!
  "Run `f` on every node after processing. `f` is called with `[node]`; its
  return value is ignored."
  [^HtmlSanitizer s f]
  (.onPostProcessNode s (when f
                          (reify HtmlSanitizer$PostProcessHandler
                            (onPostProcess [_ node] (f node) nil))))
  s)

(defn each-document!
  "Run `f` on the whole document after processing. `f` is called with `[doc]`."
  [^HtmlSanitizer s f]
  (.onPostProcessDom s (when f
                         (reify HtmlSanitizer$PostProcessHandler
                           (onPostProcess [_ doc] (f doc) nil))))
  s)

(defn rewrite-urls!
  "Install a URL rewriter. `f` is called with `[element raw resolved]` and must
  return the URL to use; an **empty string drops** the attribute.

  Returning nil means 'no rewrite' — the resolved URL is used — rather than an
  empty string, since a fn falling off the end should not silently strip every
  URL in the document."
  [^HtmlSanitizer s f]
  (.onFilterUrl s (when f
                    (reify HtmlSanitizer$FilterUrlHandler
                      (onFilterUrl [_ elem raw resolved]
                        (let [out (f elem raw resolved)]
                          (if (nil? out) resolved (str out)))))))
  s)

;; ---- configuration in one expression -------------------------------------

(defn configure!
  "Apply a map of settings to a sanitizer, and return it.

  A data-driven alternative to threading the setters, for when a policy is
  itself a value:

      (with-open [s (configure! (sanitizer)
                                {:keep-child-nodes true
                                 :allow            {:tags [\"my-widget\"]}
                                 :disallow         {:tags [\"script\"]}
                                 :keep-tag-if      (fn [n _] (= \"keep-me\" (node-name n)))})]
        ...)

  Recognised keys: `:keep-child-nodes`, `:allow-data-attributes`, `:allow`,
  `:disallow`, `:keep-tag-if`, `:keep-attribute-if`, `:keep-style-if`,
  `:keep-comment-if`, `:each-node`, `:each-document`, `:rewrite-urls`."
  [^HtmlSanitizer s {:keys [keep-child-nodes allow-data-attributes
                            allow disallow
                            keep-tag-if keep-attribute-if keep-style-if
                            keep-comment-if each-node each-document
                            rewrite-urls]}]
  (when (some? keep-child-nodes) (keep-child-nodes! s keep-child-nodes))
  (when (some? allow-data-attributes) (allow-data-attributes! s allow-data-attributes))
  (doseq [[which items] allow] (apply allow! s which items))
  (doseq [[which items] disallow] (apply disallow! s which items))
  (when keep-tag-if (keep-tag-if! s keep-tag-if))
  (when keep-attribute-if (keep-attribute-if! s keep-attribute-if))
  (when keep-style-if (keep-style-if! s keep-style-if))
  (when keep-comment-if (keep-comment-if! s keep-comment-if))
  (when each-node (each-node! s each-node))
  (when each-document (each-document! s each-document))
  (when rewrite-urls (rewrite-urls! s rewrite-urls))
  s)
