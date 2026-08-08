"
I clean HTML of constructs that can lead to XSS.

```
sanitizer := HtmlSanitizer new.
[ sanitizer sanitize: '<div onclick=''alert(1)''>Hello</div>' ]
	ensure: [ sanitizer close ].
"" -> '<div>Hello</div>' ""
```

or, letting the block manage the handle:

```
HtmlSanitizer during: [ :s | s sanitize: '<div>x</div>' ].
```

## No sanitizer logic here

I am **marshalling only**. The engine — HTML5 tokenizer, DOM, CSS parser, URL
resolver, allow-lists — is the pure-Aether `core/htmlsanitizer.ae`, shared by
every language binding in this monorepo and reached through the
`aether_hs_embed_*` C ABI (`core/embed.ae`). Naming: `core/embed.ae` declares
`hs_embed_<name>`; `--emit=lib` mangles that to `aether_hs_embed_<name>`, which
is what the FFI calls below name.

## The two ownership rules

1. **Every `char*` the ABI returns is caller-owned.** `takeString:` copies it
   and frees it through `aether_hs_embed_free_string`. Anything else leaks —
   this is the single most common bug in a binding of this ABI.
2. **Node and attribute pointers handed to a callback are borrowed**, valid
   only for that callback: the DOM is freed when `sanitize` returns. Never
   retain one. Use `HsNode >> asDictionary` to snapshot instead.

## Callbacks

The engine's C trampolines pass the registered `user_data` as the **first**
argument, and every integer is a C `int` (not `long`). For the `removing*`
family a **non-zero return CANCELS the removal** — it keeps the node. The
`when*` methods below take a block and hide the inversion behind a name that
says which way it goes.

I am **not thread-safe**: the engine calls hooks re-entrantly during
`sanitize`.
"
Class {
	#name : 'HtmlSanitizer',
	#superclass : 'Object',
	#instVars : [
		'handle',
		'callbacks',
		'removingTagBlock',
		'removingAttributeBlock',
		'removingStyleBlock',
		'removingCommentBlock',
		'postProcessNodeBlock',
		'postProcessDomBlock',
		'filterUrlBlock'
	],
	#category : 'HtmlSanitizer',
	#package : 'HtmlSanitizer'
}


{ #category : 'constants' }
HtmlSanitizer class >> selectorTags [ ^ 0 ]

{ #category : 'constants' }
HtmlSanitizer class >> selectorAttributes [ ^ 1 ]

{ #category : 'constants' }
HtmlSanitizer class >> selectorCssProperties [ ^ 2 ]

{ #category : 'constants' }
HtmlSanitizer class >> selectorSchemes [ ^ 3 ]

{ #category : 'constants' }
HtmlSanitizer class >> selectorClasses [ ^ 4 ]

{ #category : 'constants' }
HtmlSanitizer class >> selectorUriAttributes [ ^ 5 ]

{ #category : 'constants' }
HtmlSanitizer class >> selectorFor: aSymbol [
	"Map a friendly symbol onto the ABI's integer selector."

	^ aSymbol
		  caseOf: {
			  [ #tags ] -> [ self selectorTags ].
			  [ #attributes ] -> [ self selectorAttributes ].
			  [ #cssProperties ] -> [ self selectorCssProperties ].
			  [ #schemes ] -> [ self selectorSchemes ].
			  [ #classes ] -> [ self selectorClasses ].
			  [ #uriAttributes ] -> [ self selectorUriAttributes ] }
		  otherwise: [
			  self error: 'unknown allow-list ' , aSymbol printString
				  , ' (expected one of #tags #attributes #cssProperties #schemes #classes #uriAttributes)' ]
]


{ #category : 'constants' }
HtmlSanitizer class >> reasonSymbolFor: anInteger [
	"The ABI removal-reason code as a Symbol, or #unknown for a code this
	 build does not know. The constants are append-only, so a newer engine is
	 not an error."

	^ anInteger
		  caseOf: {
			  [ 0 ] -> [ #notAllowedTag ].
			  [ 1 ] -> [ #notAllowedAttribute ].
			  [ 2 ] -> [ #notAllowedStyle ].
			  [ 3 ] -> [ #notAllowedUrlValue ].
			  [ 4 ] -> [ #notAllowedValue ].
			  [ 5 ] -> [ #notAllowedCssClass ].
			  [ 6 ] -> [ #classAttributeEmpty ].
			  [ 7 ] -> [ #styleAttributeEmpty ] }
		  otherwise: [ #unknown ]
]


{ #category : 'constants' }
HtmlSanitizer class >> nodeKindDocument [ ^ 1 ]

{ #category : 'constants' }
HtmlSanitizer class >> nodeKindElement [ ^ 2 ]

{ #category : 'constants' }
HtmlSanitizer class >> nodeKindText [ ^ 3 ]

{ #category : 'constants' }
HtmlSanitizer class >> nodeKindComment [ ^ 4 ]

{ #category : 'constants' }
HtmlSanitizer class >> nodeKindSymbolFor: anInteger [

	^ anInteger
		  caseOf: {
			  [ 1 ] -> [ #document ].
			  [ 2 ] -> [ #element ].
			  [ 3 ] -> [ #text ].
			  [ 4 ] -> [ #comment ] }
		  otherwise: [ #unknown ]
]


{ #category : 'instance creation' }
HtmlSanitizer class >> new [

	^ self basicNew initialize
]

{ #category : 'instance creation' }
HtmlSanitizer class >> during: aBlock [
	"Create a sanitizer, hand it to aBlock, and close it — whatever happens.
	 The safe default, since the handle is native memory."

	| s |
	s := self new.
	^ [ aBlock value: s ] ensure: [ s close ]
]

{ #category : 'instance creation' }
HtmlSanitizer class >> sanitize: anHtmlString [
	"Sanitize one fragment with the secure defaults, closing immediately."

	^ self during: [ :s | s sanitize: anHtmlString ]
]

{ #category : 'accessing' }
HtmlSanitizer class >> abiVersion [
	"The engine's ABI revision. A class-side convenience: it needs no handle."

	^ self primAbiVersion
]


{ #category : 'private - ffi' }
HtmlSanitizer class >> primAbiVersion [

	^ self ffiCall: #( int aether_hs_embed_abi_version ( void ) )
]

{ #category : 'private - ffi' }
HtmlSanitizer >> ffiLibrary [

	^ HtmlSanitizerLibrary
]

{ #category : 'private - ffi' }
HtmlSanitizer class >> ffiLibrary [

	^ HtmlSanitizerLibrary
]

{ #category : 'private - ffi - lifecycle' }
HtmlSanitizer >> primNew [

	^ self ffiCall: #( void * aether_hs_embed_new ( void ) )
]

{ #category : 'private - ffi - lifecycle' }
HtmlSanitizer >> primFree: aHandle [

	^ self ffiCall: #( void aether_hs_embed_free ( void * aHandle ) )
]

{ #category : 'private - ffi - lifecycle' }
HtmlSanitizer >> primFreeString: aPointer [

	^ self ffiCall: #( void aether_hs_embed_free_string ( void * aPointer ) )
]

{ #category : 'private - ffi - main' }
HtmlSanitizer >> primSanitize: aHandle html: html baseUrl: baseUrl [

	^ self ffiCall: #( void * aether_hs_embed_sanitize (
		    void * aHandle, char * html, char * baseUrl ) )
]

{ #category : 'private - ffi - main' }
HtmlSanitizer >> primSanitizeDocument: aHandle html: html baseUrl: baseUrl [

	^ self ffiCall: #( void * aether_hs_embed_sanitize_document (
		    void * aHandle, char * html, char * baseUrl ) )
]

{ #category : 'private - ffi - flags' }
HtmlSanitizer >> primSetKeepChildNodes: aHandle to: anInt [

	^ self ffiCall: #( void aether_hs_embed_set_keep_child_nodes (
		    void * aHandle, int anInt ) )
]

{ #category : 'private - ffi - flags' }
HtmlSanitizer >> primGetKeepChildNodes: aHandle [

	^ self ffiCall: #( int aether_hs_embed_get_keep_child_nodes ( void * aHandle ) )
]

{ #category : 'private - ffi - flags' }
HtmlSanitizer >> primSetAllowDataAttributes: aHandle to: anInt [

	^ self ffiCall: #( void aether_hs_embed_set_allow_data_attributes (
		    void * aHandle, int anInt ) )
]

{ #category : 'private - ffi - flags' }
HtmlSanitizer >> primGetAllowDataAttributes: aHandle [

	^ self ffiCall: #( int aether_hs_embed_get_allow_data_attributes ( void * aHandle ) )
]

{ #category : 'private - ffi - allow-lists' }
HtmlSanitizer >> primAllow: aHandle which: which item: item [

	^ self ffiCall: #( int aether_hs_embed_allow (
		    void * aHandle, int which, char * item ) )
]

{ #category : 'private - ffi - allow-lists' }
HtmlSanitizer >> primDisallow: aHandle which: which item: item [

	^ self ffiCall: #( int aether_hs_embed_disallow (
		    void * aHandle, int which, char * item ) )
]

{ #category : 'private - ffi - allow-lists' }
HtmlSanitizer >> primIsAllowed: aHandle which: which item: item [

	^ self ffiCall: #( int aether_hs_embed_is_allowed (
		    void * aHandle, int which, char * item ) )
]

{ #category : 'private - ffi - allow-lists' }
HtmlSanitizer >> primClear: aHandle which: which [

	^ self ffiCall: #( int aether_hs_embed_clear ( void * aHandle, int which ) )
]

{ #category : 'private - ffi - allow-lists' }
HtmlSanitizer >> primCount: aHandle which: which [

	^ self ffiCall: #( int aether_hs_embed_count ( void * aHandle, int which ) )
]

{ #category : 'private - ffi - allow-lists' }
HtmlSanitizer >> primItemAt: aHandle which: which index: index [

	^ self ffiCall: #( void * aether_hs_embed_item_at (
		    void * aHandle, int which, int index ) )
]

{ #category : 'private - ffi - callbacks' }
HtmlSanitizer >> primOnRemovingTag: aHandle fn: fn userData: ud [

	^ self ffiCall: #( void aether_hs_embed_on_removing_tag (
		    void * aHandle, void * fn, void * ud ) )
]

{ #category : 'private - ffi - callbacks' }
HtmlSanitizer >> primOnRemovingAttribute: aHandle fn: fn userData: ud [

	^ self ffiCall: #( void aether_hs_embed_on_removing_attribute (
		    void * aHandle, void * fn, void * ud ) )
]

{ #category : 'private - ffi - callbacks' }
HtmlSanitizer >> primOnRemovingStyle: aHandle fn: fn userData: ud [

	^ self ffiCall: #( void aether_hs_embed_on_removing_style (
		    void * aHandle, void * fn, void * ud ) )
]

{ #category : 'private - ffi - callbacks' }
HtmlSanitizer >> primOnRemovingComment: aHandle fn: fn userData: ud [

	^ self ffiCall: #( void aether_hs_embed_on_removing_comment (
		    void * aHandle, void * fn, void * ud ) )
]

{ #category : 'private - ffi - callbacks' }
HtmlSanitizer >> primOnPostProcessNode: aHandle fn: fn userData: ud [

	^ self ffiCall: #( void aether_hs_embed_on_post_process_node (
		    void * aHandle, void * fn, void * ud ) )
]

{ #category : 'private - ffi - callbacks' }
HtmlSanitizer >> primOnPostProcessDom: aHandle fn: fn userData: ud [

	^ self ffiCall: #( void aether_hs_embed_on_post_process_dom (
		    void * aHandle, void * fn, void * ud ) )
]

{ #category : 'private - ffi - callbacks' }
HtmlSanitizer >> primOnFilterUrl: aHandle fn: fn userData: ud [

	^ self ffiCall: #( void aether_hs_embed_on_filter_url (
		    void * aHandle, void * fn, void * ud ) )
]


{ #category : 'initialization' }
HtmlSanitizer >> initialize [

	super initialize.
	callbacks := IdentityDictionary new.
	handle := self primNew.
	(handle isNil or: [ handle isNull ]) ifTrue: [
		self error: 'failed to create the native sanitizer' ]
]

{ #category : 'lifecycle' }
HtmlSanitizer >> close [
	"Release the native handle. Freeing the engine handle also releases its
	 callback boxes, so no registered callback can fire afterwards — which is
	 what makes dropping the ExternalFunction references here safe.

	 Idempotent: closing twice is not an error."

	handle ifNil: [ ^ self ].
	self primFree: handle.
	handle := nil.
	callbacks removeAll
]

{ #category : 'lifecycle' }
HtmlSanitizer >> isClosed [

	^ handle isNil
]

{ #category : 'private' }
HtmlSanitizer >> checkOpen [

	handle ifNil: [ self error: 'sanitizer is closed' ]
]

{ #category : 'accessing' }
HtmlSanitizer >> handle [

	^ handle
]

{ #category : 'accessing' }
HtmlSanitizer >> abiVersion [

	^ self class primAbiVersion
]


{ #category : 'private - strings' }
HtmlSanitizer >> takeString: aPointer [
	"Copy an ABI-returned string out and free it through the ABI.

	 EVERY char* this ABI returns is caller-owned. Reading it without the
	 free below is a leak, and it is the easiest mistake to make here — so the
	 decode is wrapped in an ensure:, or a malformed byte sequence would leak
	 the buffer on its way out."

	| result |
	(aPointer isNil or: [ aPointer isNull ]) ifTrue: [ ^ '' ].
	result := [ self decodeUtf8: aPointer ]
		          ensure: [ self primFreeString: aPointer ].
	^ result
]

{ #category : 'private - strings' }
HtmlSanitizer >> readBorrowedString: aPointer [
	"Read a const char* the engine handed us. NOT owned by us — the engine
	 keeps it, so there is nothing to free."

	(aPointer isNil or: [ aPointer isNull ]) ifTrue: [ ^ '' ].
	^ self decodeUtf8: aPointer
]

{ #category : 'private - strings' }
HtmlSanitizer >> decodeUtf8: aPointer [
	"Decode a NUL-terminated C string as UTF-8.

	 The engine speaks UTF-8 (conformance check 04 is `café ☕` precisely to
	 pin this down). `readString` is NOT the right tool here: it answers the
	 raw bytes, so comparing its result to a String fails even for pure ASCII,
	 and a non-ASCII byte would be mangled rather than decoded.
	 `utf8StringFromCString` walks to the NUL and decodes, which is exactly
	 what makes `café ☕` survive the round trip."

	^ aPointer utf8StringFromCString
]


{ #category : 'sanitizing' }
HtmlSanitizer >> sanitize: anHtmlString [

	^ self sanitize: anHtmlString baseUrl: ''
]

{ #category : 'sanitizing' }
HtmlSanitizer >> sanitize: anHtmlString baseUrl: aBaseUrl [
	"Sanitize an HTML fragment, resolving relative URLs against aBaseUrl
	 (which may be empty)."

	self checkOpen.
	^ self takeString: (self
			   primSanitize: handle
			   html: (anHtmlString ifNil: [ '' ])
			   baseUrl: (aBaseUrl ifNil: [ '' ]))
]

{ #category : 'sanitizing' }
HtmlSanitizer >> sanitizeDocument: anHtmlString [

	^ self sanitizeDocument: anHtmlString baseUrl: ''
]

{ #category : 'sanitizing' }
HtmlSanitizer >> sanitizeDocument: anHtmlString baseUrl: aBaseUrl [
	"Sanitize a full HTML document."

	self checkOpen.
	^ self takeString: (self
			   primSanitizeDocument: handle
			   html: (anHtmlString ifNil: [ '' ])
			   baseUrl: (aBaseUrl ifNil: [ '' ]))
]


{ #category : 'configuring' }
HtmlSanitizer >> keepChildNodes [
	"Are the children of a removed element kept rather than dropped?"

	self checkOpen.
	^ (self primGetKeepChildNodes: handle) ~= 0
]

{ #category : 'configuring' }
HtmlSanitizer >> keepChildNodes: aBoolean [

	self checkOpen.
	self primSetKeepChildNodes: handle to: (aBoolean ifTrue: [ 1 ] ifFalse: [ 0 ])
]

{ #category : 'configuring' }
HtmlSanitizer >> allowDataAttributes [
	"Are data-* attributes allowed without listing each one?"

	self checkOpen.
	^ (self primGetAllowDataAttributes: handle) ~= 0
]

{ #category : 'configuring' }
HtmlSanitizer >> allowDataAttributes: aBoolean [

	self checkOpen.
	self primSetAllowDataAttributes: handle to: (aBoolean ifTrue: [ 1 ] ifFalse: [ 0 ])
]


{ #category : 'allow-lists' }
HtmlSanitizer >> allow: anItem on: aSelectorSymbol [

	self checkOpen.
	self
		primAllow: handle
		which: (self class selectorFor: aSelectorSymbol)
		item: anItem.
	^ self
]

{ #category : 'allow-lists' }
HtmlSanitizer >> allowAll: aCollection on: aSelectorSymbol [

	aCollection do: [ :each | self allow: each on: aSelectorSymbol ].
	^ self
]

{ #category : 'allow-lists' }
HtmlSanitizer >> disallow: anItem on: aSelectorSymbol [
	"The deny direction — drop an entry that is currently allowed."

	self checkOpen.
	self
		primDisallow: handle
		which: (self class selectorFor: aSelectorSymbol)
		item: anItem.
	^ self
]

{ #category : 'allow-lists' }
HtmlSanitizer >> disallowAll: aCollection on: aSelectorSymbol [

	aCollection do: [ :each | self disallow: each on: aSelectorSymbol ].
	^ self
]

{ #category : 'allow-lists' }
HtmlSanitizer >> isAllowed: anItem on: aSelectorSymbol [

	self checkOpen.
	^ (self
		   primIsAllowed: handle
		   which: (self class selectorFor: aSelectorSymbol)
		   item: anItem) ~= 0
]

{ #category : 'allow-lists' }
HtmlSanitizer >> clear: aSelectorSymbol [
	"Empty a list — the 'start from nothing' move for a strict policy."

	self checkOpen.
	self primClear: handle which: (self class selectorFor: aSelectorSymbol).
	^ self
]

{ #category : 'allow-lists' }
HtmlSanitizer >> countOn: aSelectorSymbol [

	self checkOpen.
	^ self primCount: handle which: (self class selectorFor: aSelectorSymbol)
]

{ #category : 'allow-lists' }
HtmlSanitizer >> allowedOn: aSelectorSymbol [
	"Snapshot a list as a Set of Strings. Iteration order is unspecified;
	 each entry appears once."

	| which n out |
	self checkOpen.
	which := self class selectorFor: aSelectorSymbol.
	n := self primCount: handle which: which.
	out := Set new.
	0 to: n - 1 do: [ :i |
		out add:
			(self takeString: (self primItemAt: handle which: which index: i)) ].
	^ out
]

{ #category : 'allow-lists' }
HtmlSanitizer >> replace: aCollection on: aSelectorSymbol [
	"Clear a list and set it to exactly aCollection."

	self clear: aSelectorSymbol.
	^ self allowAll: aCollection on: aSelectorSymbol
]


{ #category : 'private - callbacks' }
HtmlSanitizer >> rememberCallback: aCallback at: aKey [
	"Keep a strong reference for as long as the engine might call it."

	callbacks at: aKey put: aCallback.
	^ aCallback
]

{ #category : 'private - callbacks' }
HtmlSanitizer >> booleanToAbi: anObject [
	"Smalltalk truth to the ABI's cancel flag. Anything other than true —
	 including nil from a block that fell off the end — means 'do not keep',
	 which is the safe direction for a sanitizer."

	^ anObject == true ifTrue: [ 1 ] ifFalse: [ 0 ]
]

{ #category : 'callbacks' }
HtmlSanitizer >> whenRemovingTag: aBlock [
	"Install a hook run before a tag is removed. aBlock is called with
	 [ :node :reasonSymbol ] and returning TRUE KEEPS the tag.

	 Pass nil to clear the hook."

	| cb |
	self checkOpen.
	removingTagBlock := aBlock.
	aBlock ifNil: [
		self primOnRemovingTag: handle fn: ExternalAddress null userData: ExternalAddress null.
		callbacks removeKey: #removingTag ifAbsent: [ nil ].
		^ self ].
	cb := FFICallback
		      signature: #( int ( void * ud, void * node, int reason ) )
		      block: [ :ud :node :reason |
			      self booleanToAbi: (removingTagBlock
					       value: (HsNode on: node sanitizer: self)
					       value: (self class reasonSymbolFor: reason)) ].
	self rememberCallback: cb at: #removingTag.
	self primOnRemovingTag: handle fn: cb getHandle userData: ExternalAddress null.
	^ self
]

{ #category : 'callbacks' }
HtmlSanitizer >> whenRemovingAttribute: aBlock [
	"aBlock is called with [ :element :attribute :reasonSymbol ] and returning
	 TRUE KEEPS the attribute."

	| cb |
	self checkOpen.
	removingAttributeBlock := aBlock.
	aBlock ifNil: [
		self primOnRemovingAttribute: handle fn: ExternalAddress null userData: ExternalAddress null.
		callbacks removeKey: #removingAttribute ifAbsent: [ nil ].
		^ self ].
	cb := FFICallback
		      signature: #( int ( void * ud, void * elem, void * attr, int reason ) )
		      block: [ :ud :elem :attr :reason |
			      self booleanToAbi: (removingAttributeBlock
					       value: (HsNode on: elem sanitizer: self)
					       value: (HsAttribute on: attr sanitizer: self)
					       value: (self class reasonSymbolFor: reason)) ].
	self rememberCallback: cb at: #removingAttribute.
	self primOnRemovingAttribute: handle fn: cb getHandle userData: ExternalAddress null.
	^ self
]

{ #category : 'callbacks' }
HtmlSanitizer >> whenRemovingStyle: aBlock [
	"aBlock is called with [ :element :name :value :reasonSymbol ] and
	 returning TRUE KEEPS the CSS property."

	| cb |
	self checkOpen.
	removingStyleBlock := aBlock.
	aBlock ifNil: [
		self primOnRemovingStyle: handle fn: ExternalAddress null userData: ExternalAddress null.
		callbacks removeKey: #removingStyle ifAbsent: [ nil ].
		^ self ].
	cb := FFICallback
		      "void *, not char *, for the string params: `char *` would make
		       UnifiedFFI decode them for us, and this binding owns its UTF-8
		       handling (see decodeUtf8:)."
		      signature: #( int ( void * ud, void * elem, void * name, void * value, int reason ) )
		      block: [ :ud :elem :name :value :reason |
			      self booleanToAbi: (removingStyleBlock
					       value: (HsNode on: elem sanitizer: self)
					       value: (self readBorrowedString: name)
					       value: (self readBorrowedString: value)
					       value: (self class reasonSymbolFor: reason)) ].
	self rememberCallback: cb at: #removingStyle.
	self primOnRemovingStyle: handle fn: cb getHandle userData: ExternalAddress null.
	^ self
]

{ #category : 'callbacks' }
HtmlSanitizer >> whenRemovingComment: aBlock [
	"aBlock is called with [ :node ] and returning TRUE KEEPS the comment."

	| cb |
	self checkOpen.
	removingCommentBlock := aBlock.
	aBlock ifNil: [
		self primOnRemovingComment: handle fn: ExternalAddress null userData: ExternalAddress null.
		callbacks removeKey: #removingComment ifAbsent: [ nil ].
		^ self ].
	cb := FFICallback
		      signature: #( int ( void * ud, void * node ) )
		      block: [ :ud :node |
			      self booleanToAbi:
					      (removingCommentBlock value: (HsNode on: node sanitizer: self)) ].
	self rememberCallback: cb at: #removingComment.
	self primOnRemovingComment: handle fn: cb getHandle userData: ExternalAddress null.
	^ self
]

{ #category : 'callbacks' }
HtmlSanitizer >> whenPostProcessingNode: aBlock [
	"aBlock is called with [ :node ] after each node is processed. Its value
	 is ignored."

	| cb |
	self checkOpen.
	postProcessNodeBlock := aBlock.
	aBlock ifNil: [
		self primOnPostProcessNode: handle fn: ExternalAddress null userData: ExternalAddress null.
		callbacks removeKey: #postProcessNode ifAbsent: [ nil ].
		^ self ].
	cb := FFICallback
		      signature: #( void ( void * ud, void * node ) )
		      block: [ :ud :node |
			      postProcessNodeBlock value: (HsNode on: node sanitizer: self) ].
	self rememberCallback: cb at: #postProcessNode.
	self primOnPostProcessNode: handle fn: cb getHandle userData: ExternalAddress null.
	^ self
]

{ #category : 'callbacks' }
HtmlSanitizer >> whenPostProcessingDocument: aBlock [
	"aBlock is called with [ :document ] once the whole DOM is processed."

	| cb |
	self checkOpen.
	postProcessDomBlock := aBlock.
	aBlock ifNil: [
		self primOnPostProcessDom: handle fn: ExternalAddress null userData: ExternalAddress null.
		callbacks removeKey: #postProcessDom ifAbsent: [ nil ].
		^ self ].
	cb := FFICallback
		      signature: #( void ( void * ud, void * node ) )
		      block: [ :ud :node |
			      postProcessDomBlock value: (HsNode on: node sanitizer: self) ].
	self rememberCallback: cb at: #postProcessDom.
	self primOnPostProcessDom: handle fn: cb getHandle userData: ExternalAddress null.
	^ self
]

{ #category : 'callbacks' }
HtmlSanitizer >> whenFilteringUrl: aBlock [
	"aBlock is called with [ :element :raw :resolved ] and must answer the URL
	 to use; an EMPTY STRING drops the attribute.

	 Answering nil means 'no rewrite' — the resolved URL is used — because a
	 block falling off the end should not silently strip every URL.

	 OWNERSHIP: the engine takes the returned buffer and frees it with libc
	 free, so it must be a libc-malloc'd copy. `ExternalAddress allocate:` is
	 malloc underneath, which is the matching allocator.

	 The signature says `void *` throughout rather than `char *`, and that is
	 load-bearing in BOTH directions. For the parameters, `char *` would make
	 UnifiedFFI hand the block an already-decoded String, which is the wrong
	 layer to decode at — this binding owns its UTF-8 handling. For the RETURN
	 value it is worse: with `char *` the callback tries to marshal the
	 ExternalAddress we answer as though it were a Smalltalk String, and dies
	 with `Character doesNotUnderstand: #isExternalAddress` mid-sanitize.
	 Returning a raw `void *` hands the engine exactly the pointer it expects."

	| cb |
	self checkOpen.
	filterUrlBlock := aBlock.
	aBlock ifNil: [
		self primOnFilterUrl: handle fn: ExternalAddress null userData: ExternalAddress null.
		callbacks removeKey: #filterUrl ifAbsent: [ nil ].
		^ self ].
	cb := FFICallback
		      signature: #( void * ( void * ud, void * elem, void * raw, void * resolved ) )
		      block: [ :ud :elem :raw :resolved |
			      | answer |
			      answer := filterUrlBlock
					            value: (HsNode on: elem sanitizer: self)
					            value: (self readBorrowedString: raw)
					            value: (self readBorrowedString: resolved).
			      answer
				      ifNil: [ resolved ]
				      ifNotNil: [ self mallocString: answer asString ] ].
	self rememberCallback: cb at: #filterUrl.
	self primOnFilterUrl: handle fn: cb getHandle userData: ExternalAddress null.
	^ self
]

{ #category : 'private - strings' }
HtmlSanitizer >> mallocString: aString [
	"A libc-malloc'd, NUL-terminated copy of aString, which the ENGINE then
	 owns and frees. Not freed here — that is the on_filter_url contract, the
	 same one attr_set_value uses."

	| bytes address |
	bytes := aString utf8Encoded.
	address := ExternalAddress allocate: bytes size + 1.
	1 to: bytes size do: [ :i |
		address unsignedByteAt: i put: (bytes at: i) ].
	address unsignedByteAt: bytes size + 1 put: 0.
	^ address
]


{ #category : 'configuring' }
HtmlSanitizer >> configure: aBlock [
	"Run aBlock with the receiver, and answer the receiver — so a policy can
	 be written as one cascade-ish expression and still be chained."

	aBlock value: self.
	^ self
]
