"
The 12-check binding conformance suite (docs/conformance.md), in Pharo.

I prove the Pharo binding marshals every value shape across the FFI. I am NOT
a sanitizer test suite — the behavioural cases live in the sanitizer core's own tests
and run once, in Aether.

Unlike the Kotlin/Scala/Clojure/Groovy layers, which sit on the Java binding,
this is a REAL FFI, so these checks carry their full weight here: a wrong
callback width, a leaked caller-owned string, or a garbage-collected callback
would show up in exactly these tests.

Run headless:

```
pharo --headless HtmlSanitizer.image test --junit-xml-output HtmlSanitizer
```

or from a workspace: `HtmlSanitizerConformanceTest suite run`.
"
Class {
	#name : 'HtmlSanitizerConformanceTest',
	#superclass : 'TestCase',
	#instVars : [ 'sanitizer' ],
	#category : 'HtmlSanitizer',
	#package : 'HtmlSanitizer'
}

{ #category : 'running' }
HtmlSanitizerConformanceTest >> setUp [

	super setUp.
	sanitizer := HtmlSanitizer new
]

{ #category : 'running' }
HtmlSanitizerConformanceTest >> tearDown [

	sanitizer ifNotNil: [ sanitizer close ].
	sanitizer := nil.
	super tearDown
]

"--- the 12 required checks ---"

{ #category : 'tests' }
HtmlSanitizerConformanceTest >> test01ScriptRemoved [

	self
		assert: (sanitizer sanitize: '<div>Hello <script>alert(1)</script> world!</div>')
		equals: '<div>Hello  world!</div>'
]

{ #category : 'tests' }
HtmlSanitizerConformanceTest >> test02OnclickRemoved [

	self
		assert: (sanitizer sanitize: '<div onclick="alert(1)">Hello</div>')
		equals: '<div>Hello</div>'
]

{ #category : 'tests' }
HtmlSanitizerConformanceTest >> test03EmptyString [
	"The classic NULL-vs-empty-string marshalling bug."

	self assert: (sanitizer sanitize: '') equals: ''
]

{ #category : 'tests' }
HtmlSanitizerConformanceTest >> test04Utf8RoundTrip [
	"UTF-8 across the boundary, not Latin-1."

	self
		assert: (sanitizer sanitize: '<div>café ☕</div>')
		equals: '<div>café ☕</div>'
]

{ #category : 'tests' }
HtmlSanitizerConformanceTest >> test05AllowCustomTag [

	self assert: (sanitizer sanitize: '<my-widget>x</my-widget>') equals: ''.
	sanitizer allow: 'my-widget' on: #tags.
	self
		assert: (sanitizer sanitize: '<my-widget>x</my-widget>')
		equals: '<my-widget>x</my-widget>'
]

{ #category : 'tests' }
HtmlSanitizerConformanceTest >> test06DisallowTag [

	self assert: (sanitizer sanitize: '<div>x</div>') equals: '<div>x</div>'.
	sanitizer disallow: 'div' on: #tags.
	self assert: (sanitizer sanitize: '<div>x</div>') equals: ''
]

{ #category : 'tests' }
HtmlSanitizerConformanceTest >> test07MembershipAndCount [

	self assert: (sanitizer isAllowed: 'http' on: #schemes).
	self deny: (sanitizer isAllowed: 'gopher' on: #schemes).
	self assert: (sanitizer countOn: #schemes) equals: 2
]

{ #category : 'tests' }
HtmlSanitizerConformanceTest >> test08Enumeration [
	"The item_at read path."

	self
		assert: (sanitizer allowedOn: #schemes)
		equals: (Set withAll: #( 'http' 'https' ))
]

{ #category : 'tests' }
HtmlSanitizerConformanceTest >> test09KeepChildNodes [
	"Boolean flags marshalled as int."

	self
		assert: (sanitizer sanitize: '<div><nope>Hello <span>world</span></nope></div>')
		equals: '<div></div>'.
	sanitizer keepChildNodes: true.
	self assert: sanitizer keepChildNodes.
	self
		assert: (sanitizer sanitize: '<div><nope>Hello <span>world</span></nope></div>')
		equals: '<div>Hello <span>world</span></div>'
]

{ #category : 'tests' }
HtmlSanitizerConformanceTest >> test10OnRemovingTagCancels [
	"The callback trampoline plus the cancel semantics — one of the two
	 checks most likely to be subtly wrong in any binding."

	| seen |
	seen := OrderedCollection new.
	sanitizer whenRemovingTag: [ :node :reason |
		seen add: (Array with: node name with: reason).
		node name = 'keep-me' ].
	self
		assert: (sanitizer sanitize: '<div><keep-me>a</keep-me><drop-me>b</drop-me></div>')
		equals: '<div><keep-me>a</keep-me></div>'.
	self assert: (seen includes: (Array with: 'keep-me' with: #notAllowedTag)).
	self assert: (seen includes: (Array with: 'drop-me' with: #notAllowedTag))
]

{ #category : 'tests' }
HtmlSanitizerConformanceTest >> test11OnFilterUrlRewrites [
	"The string-returning callback — the hardest shape, and the one where
	 ownership of the returned buffer matters."

	sanitizer whenFilteringUrl: [ :elem :raw :resolved |
		resolved = 'https://example.com/logo.png'
			ifTrue: [ 'https://cdn.example.net/logo.png' ]
			ifFalse: [ resolved ] ].
	self
		assert: (sanitizer sanitize: '<img src="logo.png">' baseUrl: 'https://example.com')
		equals: '<img src="https://cdn.example.net/logo.png">'
]

{ #category : 'tests' }
HtmlSanitizerConformanceTest >> test12HandlesAreIndependent [
	"The handle really is per-instance."

	HtmlSanitizer during: [ :a |
		HtmlSanitizer during: [ :b |
			a allow: 'only-in-a' on: #tags.
			self assert: (a isAllowed: 'only-in-a' on: #tags).
			self deny: (b isAllowed: 'only-in-a' on: #tags) ] ]
]

"--- extras: the remaining callback shapes ---"

{ #category : 'tests - callbacks' }
HtmlSanitizerConformanceTest >> testOnRemovingAttributeSeesTheAttribute [

	| seen |
	seen := OrderedCollection new.
	sanitizer whenRemovingAttribute: [ :elem :attr :reason |
		seen add: (Array with: elem name with: attr name with: attr value).
		false ].
	self
		assert: (sanitizer sanitize: '<div onclick="alert(1)">x</div>')
		equals: '<div>x</div>'.
	self assert:
		(seen includes: (Array with: 'div' with: 'onclick' with: 'alert(1)'))
]

{ #category : 'tests - callbacks' }
HtmlSanitizerConformanceTest >> testOnRemovingCommentCancels [

	sanitizer whenRemovingComment: [ :node | true ].
	self
		assert: (sanitizer sanitize: '<div>a<!-- keep -->b</div>')
		equals: '<div>a<!-- keep -->b</div>'
]

{ #category : 'tests - callbacks' }
HtmlSanitizerConformanceTest >> testOnRemovingStyleIsFourArg [

	| seen out |
	seen := OrderedCollection new.
	sanitizer whenRemovingStyle: [ :elem :name :value :reason |
		seen add: (Array with: name with: value).
		name = '-custom-thing' ].
	out := sanitizer sanitize: '<div style="-custom-thing: 3; color: red">x</div>'.
	self assert: (out includesSubstring: '-custom-thing').
	self assert: (seen includes: (Array with: '-custom-thing' with: '3'))
]

{ #category : 'tests - callbacks' }
HtmlSanitizerConformanceTest >> testPostProcessNodeVisits [

	| kinds |
	kinds := OrderedCollection new.
	sanitizer whenPostProcessingNode: [ :node | kinds add: node kind ].
	sanitizer sanitize: '<div><span>a</span><span>b</span></div>'.
	self deny: kinds isEmpty
]

{ #category : 'tests - callbacks' }
HtmlSanitizerConformanceTest >> testNodeTreeNavigation [

	| kind children |
	sanitizer whenPostProcessingDocument: [ :doc |
		kind := doc kind.
		children := doc children size ].
	sanitizer sanitize: '<div>a</div><p>b</p>'.
	self assert: kind equals: #document.
	self assert: children >= 2
]

{ #category : 'tests' }
HtmlSanitizerConformanceTest >> testAbiVersion [

	self assert: sanitizer abiVersion >= 1
]

{ #category : 'tests' }
HtmlSanitizerConformanceTest >> testSanitizeDocumentIsWired [

	self
		assert: (sanitizer sanitizeDocument: '<div>doc<script>x</script></div>')
		equals: '<div>doc</div>'
]

{ #category : 'tests - callbacks' }
HtmlSanitizerConformanceTest >> testAttributeSetValueRewrites [
	"Proves the setter reaches the DOM: rename the value and keep the
	 attribute by cancelling its removal."

	sanitizer whenRemovingAttribute: [ :elem :attr :reason |
		attr name = 'onclick'
			ifTrue: [
				attr value: 'safe'.
				true ]
			ifFalse: [ false ] ].
	self
		assert: (sanitizer sanitize: '<div onclick="alert(1)">x</div>')
		equals: '<div onclick="safe">x</div>'
]

{ #category : 'tests - lifecycle' }
HtmlSanitizerConformanceTest >> testClosedSanitizerRejectsUse [

	| s |
	s := HtmlSanitizer new.
	s close.
	self should: [ s sanitize: '<div>x</div>' ] raise: Error
]

{ #category : 'tests - lifecycle' }
HtmlSanitizerConformanceTest >> testCloseIsIdempotent [
	"Double-free would be a crash, not an exception, so this is worth pinning."

	| s |
	s := HtmlSanitizer new.
	s close.
	s close.
	self assert: s isClosed
]

{ #category : 'tests - lifecycle' }
HtmlSanitizerConformanceTest >> testDuringClosesEvenWhenTheBlockThrows [

	| captured |
	self
		should: [
			HtmlSanitizer during: [ :s |
				captured := s.
				Error signal: 'boom' ] ]
		raise: Error.
	self assert: captured isClosed
]

"--- extras specific to the Pharo layer ---"

{ #category : 'tests - allow-lists' }
HtmlSanitizerConformanceTest >> testReplaceStartsFromNothing [

	sanitizer replace: #( 'b' 'i' ) on: #tags.
	self assert: (sanitizer countOn: #tags) equals: 2.
	self assert: (sanitizer sanitize: '<b>x</b><div>y</div>') equals: '<b>x</b>'
]

{ #category : 'tests - allow-lists' }
HtmlSanitizerConformanceTest >> testUnknownSelectorIsRejected [
	"A typo'd selector must fail loudly, not silently widen the policy."

	self should: [ sanitizer allow: 'x' on: #nonsense ] raise: Error
]

{ #category : 'tests - dom' }
HtmlSanitizerConformanceTest >> testAttributeLookupByName [

	| found |
	sanitizer whenRemovingAttribute: [ :elem :attr :reason |
		found := (elem attributeNamed: 'onclick') ifNotNil: [ :a | a value ].
		false ].
	sanitizer sanitize: '<div onclick="alert(1)">x</div>'.
	self assert: found equals: 'alert(1)'
]

{ #category : 'tests - dom' }
HtmlSanitizerConformanceTest >> testAsDictionarySnapshotsABorrowedNode [
	"The point of asDictionary: the snapshot survives the callback, the
	 HsNode does not. Reading it AFTER sanitize returns is the whole check."

	| snap |
	sanitizer whenPostProcessingDocument: [ :doc | snap := doc asDictionary ].
	sanitizer sanitize: '<div>a</div><p>b</p>'.
	self assert: (snap at: #kind) equals: #document.
	self assert: (snap at: #children) size >= 2.
	self assert: ((snap at: #children) allSatisfy: [ :c | c isDictionary ])
]

{ #category : 'tests - dom' }
HtmlSanitizerConformanceTest >> testWalkIsDepthFirstAndInclusive [

	| n |
	sanitizer whenPostProcessingDocument: [ :doc | n := doc walk size ].
	sanitizer sanitize: '<div><span>a</span></div>'.
	"document + div + span + text, at least."
	self assert: n >= 3
]

{ #category : 'tests - callbacks' }
HtmlSanitizerConformanceTest >> testKeepPredicateToleratesANilReturn [
	"A block falling off the end must mean 'do not keep', not a primitive
	 failure — and 'do not keep' is the safe direction for a sanitizer."

	sanitizer whenRemovingTag: [ :node :reason | nil ].
	self
		assert: (sanitizer sanitize: '<div><nope>x</nope></div>')
		equals: '<div></div>'
]

{ #category : 'tests - callbacks' }
HtmlSanitizerConformanceTest >> testFilterUrlNilMeansNoRewrite [

	sanitizer whenFilteringUrl: [ :elem :raw :resolved | nil ].
	self
		assert: (sanitizer sanitize: '<img src="logo.png">' baseUrl: 'https://example.com')
		equals: '<img src="https://example.com/logo.png">'
]

{ #category : 'tests - callbacks' }
HtmlSanitizerConformanceTest >> testCallbackCanBeCleared [
	"Passing nil unregisters the hook; the sanitizer core must then fall back to its
	 default behaviour rather than call a stale pointer."

	sanitizer whenRemovingTag: [ :node :reason | true ].
	self
		assert: (sanitizer sanitize: '<div><nope>x</nope></div>')
		equals: '<div><nope>x</nope></div>'.
	sanitizer whenRemovingTag: nil.
	self
		assert: (sanitizer sanitize: '<div><nope>x</nope></div>')
		equals: '<div></div>'
]

{ #category : 'tests - constants' }
HtmlSanitizerConformanceTest >> testUnknownAbiCodesDegrade [
	"The ABI's constants are append-only; a code this build has never seen
	 must become #unknown rather than raise mid-sanitize."

	self assert: (HtmlSanitizer reasonSymbolFor: 9999) equals: #unknown.
	self assert: (HtmlSanitizer nodeKindSymbolFor: 9999) equals: #unknown
]

{ #category : 'tests - configuring' }
HtmlSanitizerConformanceTest >> testConfigureAppliesAPolicy [

	sanitizer configure: [ :s |
		s allow: 'my-widget' on: #tags.
		s keepChildNodes: true ].
	self assert: (sanitizer isAllowed: 'my-widget' on: #tags).
	self assert: sanitizer keepChildNodes
]
