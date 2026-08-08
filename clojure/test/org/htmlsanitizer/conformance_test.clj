(ns org.htmlsanitizer.conformance-test
  "The 12-check binding conformance suite (docs/conformance.md), in Clojure.

  Proves the **Clojure layer** marshals every value shape correctly. Since that
  layer sits on the Java binding rather than on its own FFI, what this suite
  really pins down is that the Clojure wrapping — `reify`d SAM callbacks,
  keyword reasons, the live allow-list fns — reaches the same engine behaviour
  the Java and Python suites see. A `reify` that returned the wrong type, or an
  `allow!` that mutated a copy instead of the live view, would fail here and
  nowhere else.

  It is NOT a sanitizer test suite — the behavioural cases live in the engine's
  own tests and run once, in Aether.

  `clojure.test` rather than an external framework, so the run needs nothing but
  the Clojure jar itself: it works offline and cannot fail resolving a
  test-framework artifact."
  (:require [clojure.test :refer [deftest is run-tests testing]]
            [org.htmlsanitizer.core :as hs])
  (:import (org.htmlsanitizer HtmlSanitizer)))

;; ---- the 12 required checks ----------------------------------------------

(deftest test-01-script-removed
  (with-open [s (hs/sanitizer)]
    (is (= "<div>Hello  world!</div>"
           (hs/sanitize s "<div>Hello <script>alert(1)</script> world!</div>")))))

(deftest test-02-onclick-removed
  (with-open [s (hs/sanitizer)]
    (is (= "<div>Hello</div>" (hs/sanitize s "<div onclick=\"alert(1)\">Hello</div>")))))

(deftest test-03-empty-string
  (with-open [s (hs/sanitizer)]
    (is (= "" (hs/sanitize s "")))))

(deftest test-04-utf8-round-trip
  (with-open [s (hs/sanitizer)]
    (is (= "<div>café ☕</div>" (hs/sanitize s "<div>café ☕</div>")))))

(deftest test-05-allow-custom-tag
  (with-open [s (hs/sanitizer)]
    (is (= "" (hs/sanitize s "<my-widget>x</my-widget>")))
    (hs/allow! s :tags "my-widget")
    (is (= "<my-widget>x</my-widget>" (hs/sanitize s "<my-widget>x</my-widget>")))))

(deftest test-06-disallow-tag
  (with-open [s (hs/sanitizer)]
    (is (= "<div>x</div>" (hs/sanitize s "<div>x</div>")))
    (hs/disallow! s :tags "div")
    (is (= "" (hs/sanitize s "<div>x</div>")))))

(deftest test-07-membership-and-count
  (with-open [s (hs/sanitizer)]
    (is (hs/allowed? s :schemes "http"))
    (is (not (hs/allowed? s :schemes "gopher")))
    (is (= 2 (hs/allow-count s :schemes)))))

(deftest test-08-enumeration
  (with-open [s (hs/sanitizer)]
    (is (= #{"http" "https"} (hs/allowed s :schemes)))))

(deftest test-09-keep-child-nodes
  (with-open [s (hs/sanitizer)]
    (is (= "<div></div>" (hs/sanitize s "<div><nope>Hello <span>world</span></nope></div>")))
    (hs/keep-child-nodes! s true)
    (is (true? (hs/keep-child-nodes? s)))
    (is (= "<div>Hello <span>world</span></div>"
           (hs/sanitize s "<div><nope>Hello <span>world</span></nope></div>")))))

(deftest test-10-on-removing-tag-cancels
  (with-open [s (hs/sanitizer)]
    (let [seen (atom [])]
      (hs/keep-tag-if! s (fn [node reason]
                           (swap! seen conj [(hs/node-name node) reason])
                           (= "keep-me" (hs/node-name node))))
      (is (= "<div><keep-me>a</keep-me></div>"
             (hs/sanitize s "<div><keep-me>a</keep-me><drop-me>b</drop-me></div>")))
      (is (some #{["keep-me" :not-allowed-tag]} @seen))
      (is (some #{["drop-me" :not-allowed-tag]} @seen)))))

(deftest test-11-on-filter-url-rewrites
  (with-open [s (hs/sanitizer)]
    (hs/rewrite-urls! s (fn [_ _ resolved]
                          (if (= "https://example.com/logo.png" resolved)
                            "https://cdn.example.net/logo.png"
                            resolved)))
    (is (= "<img src=\"https://cdn.example.net/logo.png\">"
           (hs/sanitize s "<img src=\"logo.png\">" "https://example.com")))))

(deftest test-12-handles-are-independent
  (with-open [a (hs/sanitizer)
              b (hs/sanitizer)]
    (hs/allow! a :tags "only-in-a")
    (is (hs/allowed? a :tags "only-in-a"))
    (is (not (hs/allowed? b :tags "only-in-a")))))

;; ---- extras: the remaining callback shapes -------------------------------

(deftest test-on-removing-attribute-sees-the-attribute
  (with-open [s (hs/sanitizer)]
    (let [seen (atom [])]
      (hs/keep-attribute-if! s (fn [elem attr _]
                                 (swap! seen conj [(hs/node-name elem)
                                                   (hs/attr-name attr)
                                                   (hs/attr-value attr)])
                                 false))
      (is (= "<div>x</div>" (hs/sanitize s "<div onclick=\"alert(1)\">x</div>")))
      (is (some #{["div" "onclick" "alert(1)"]} @seen)))))

(deftest test-on-removing-comment-cancels
  (with-open [s (hs/sanitizer)]
    (hs/keep-comment-if! s (constantly true))
    (is (= "<div>a<!-- keep -->b</div>" (hs/sanitize s "<div>a<!-- keep -->b</div>")))))

(deftest test-on-removing-style-is-four-arg
  (with-open [s (hs/sanitizer)]
    (let [seen (atom [])]
      (hs/keep-style-if! s (fn [_ nm v _]
                             (swap! seen conj [nm v])
                             (= "-custom-thing" nm)))
      (let [out (hs/sanitize s "<div style=\"-custom-thing: 3; color: red\">x</div>")]
        (is (.contains ^String out "-custom-thing"))
        (is (some #{["-custom-thing" "3"]} @seen))))))

(deftest test-post-process-node-visits
  (with-open [s (hs/sanitizer)]
    (let [kinds (atom [])]
      (hs/each-node! s (fn [node] (swap! kinds conj (hs/node-kind node))))
      (hs/sanitize s "<div><span>a</span><span>b</span></div>")
      (is (seq @kinds)))))

(deftest test-node-tree-navigation
  (with-open [s (hs/sanitizer)]
    (let [captured (atom nil)]
      (hs/each-document! s (fn [doc]
                             (reset! captured {:kind (hs/node-kind doc)
                                               :children (count (hs/children doc))})))
      (hs/sanitize s "<div>a</div><p>b</p>")
      (is (= :document (:kind @captured)))
      (is (>= (:children @captured) 2)))))

(deftest test-abi-version
  (with-open [s (hs/sanitizer)]
    (is (>= (hs/abi-version s) 1))))

(deftest test-sanitize-document-is-wired
  (with-open [s (hs/sanitizer)]
    (is (= "<div>doc</div>" (hs/sanitize-document s "<div>doc<script>x</script></div>")))))

(deftest test-attribute-set-value-rewrites
  (with-open [s (hs/sanitizer)]
    (hs/keep-attribute-if! s (fn [_ attr _]
                               (when (= "onclick" (hs/attr-name attr))
                                 (hs/set-attr-value! attr "safe")
                                 true)))
    (is (= "<div onclick=\"safe\">x</div>"
           (hs/sanitize s "<div onclick=\"alert(1)\">x</div>")))))

(deftest test-closed-sanitizer-rejects-use
  (let [s (hs/sanitizer)]
    (hs/close! s)
    (is (thrown? IllegalStateException (hs/sanitize s "<div>x</div>")))))

;; ---- extras specific to the Clojure layer --------------------------------

(deftest test-with-open-closes-even-when-the-body-throws
  ;; A leaked native handle would be invisible to every other check, so the
  ;; with-open contract gets one of its own.
  (let [captured (atom nil)]
    (is (thrown? IllegalStateException
                 (with-open [s (hs/sanitizer)]
                   (reset! captured s)
                   (throw (IllegalStateException. "boom")))))
    (is (thrown? IllegalStateException (hs/sanitize @captured "<div>x</div>")))))

(deftest test-sanitize-once
  (is (= "<div>Hello</div>" (hs/sanitize-once "<div onclick=\"alert(1)\">Hello</div>"))))

(deftest test-configure-applies-a-policy-map
  (with-open [s (hs/configure! (hs/sanitizer)
                               {:keep-child-nodes true
                                :allow {:tags ["my-widget"]}})]
    (is (hs/allowed? s :tags "my-widget"))
    (is (true? (hs/keep-child-nodes? s)))))

(deftest test-configure-installs-callbacks
  (with-open [s (hs/configure! (hs/sanitizer)
                               {:keep-tag-if (fn [n _] (= "keep-me" (hs/node-name n)))})]
    (is (= "<div><keep-me>a</keep-me></div>"
           (hs/sanitize s "<div><keep-me>a</keep-me><drop-me>b</drop-me></div>")))))

(deftest test-replace-allowed-starts-from-nothing
  (with-open [s (hs/sanitizer)]
    (hs/replace-allowed! s :tags "b" "i")
    (is (= 2 (hs/allow-count s :tags)))
    (is (= "<b>x</b>" (hs/sanitize s "<b>x</b><div>y</div>")))))

(deftest test-attribute-lookup-by-name
  (with-open [s (hs/sanitizer)]
    (let [found (atom nil)]
      (hs/keep-attribute-if! s (fn [elem _ _]
                                 (reset! found (some-> (hs/attribute elem "onclick")
                                                       hs/attr-value))
                                 false))
      (hs/sanitize s "<div onclick=\"alert(1)\">x</div>")
      (is (= "alert(1)" @found)))))

(deftest test-node->map-snapshots-a-borrowed-node
  ;; The point of node->map: the snapshot survives the callback, the Node does
  ;; not. Reading it AFTER sanitize returns is the whole check.
  (with-open [s (hs/sanitizer)]
    (let [snap (atom nil)]
      (hs/each-document! s (fn [doc] (reset! snap (hs/node->map doc))))
      (hs/sanitize s "<div>a</div><p>b</p>")
      (is (= :document (:kind @snap)))
      (is (>= (count (:children @snap)) 2))
      ;; Nothing here touches native memory — it is plain Clojure data.
      (is (every? map? (:children @snap))))))

(deftest test-walk-is-depth-first-and-inclusive
  (with-open [s (hs/sanitizer)]
    (let [n (atom 0)]
      (hs/each-document! s (fn [doc] (reset! n (count (hs/walk doc)))))
      (hs/sanitize s "<div><span>a</span></div>")
      ;; document + div + span + text, at least.
      (is (>= @n 3)))))

(deftest test-keep-predicate-tolerates-a-nil-return
  ;; Clojure truthiness, not unboxing: a fn falling off the end must mean
  ;; "do not keep", not NullPointerException.
  (with-open [s (hs/sanitizer)]
    (hs/keep-tag-if! s (fn [_ _] nil))
    (is (= "<div></div>" (hs/sanitize s "<div><nope>x</nope></div>")))))

(deftest test-rewrite-urls-treats-nil-as-no-rewrite
  (with-open [s (hs/sanitizer)]
    (hs/rewrite-urls! s (fn [_ _ _] nil))
    (is (= "<img src=\"https://example.com/logo.png\">"
           (hs/sanitize s "<img src=\"logo.png\">" "https://example.com")))))

(deftest test-unknown-reason-codes-degrade
  ;; The ABI's constants are append-only; a code this build has never seen must
  ;; become :unknown rather than blow up mid-sanitize.
  (is (= :unknown (hs/removal-reason 9999)))
  (is (= :unknown (hs/node-kind-of 9999))))

(deftest test-allow-list-rejects-an-unknown-selector
  (with-open [s (hs/sanitizer)]
    (is (thrown? IllegalArgumentException (hs/allow-list s :not-a-list)))))

;; ---- runner --------------------------------------------------------------

(defn -main
  "Entry point for `clojure.main -m`, so the suite runs with nothing but the
  Clojure jar. Exits non-zero if anything failed, which is what the aeb node
  keys off."
  [& _args]
  (let [{:keys [fail error]} (run-tests 'org.htmlsanitizer.conformance-test)]
    (shutdown-agents)
    (System/exit (if (pos? (+ fail error)) 1 0))))
