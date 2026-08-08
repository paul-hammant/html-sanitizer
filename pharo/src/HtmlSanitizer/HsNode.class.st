"
I am a DOM node, **borrowed** for the duration of one callback.

Do not retain me past the callback that gave me to you: the DOM is freed when
`sanitize` returns, so a retained HsNode wraps a dangling pointer and reading
it is undefined behaviour.

When you want to keep something, snapshot it — `asDictionary` gives you plain
immutable Pharo data that outlives the callback:

```
sanitizer whenPostProcessingDocument: [ :doc | captured := doc asDictionary ].
```

I carry no sanitizer logic. Every accessor is one `aether_hs_embed_node_*`
call, made through the sanitizer that owns the DOM.
"
Class {
	#name : 'HsNode',
	#superclass : 'Object',
	#instVars : [ 'pointer', 'sanitizer' ],
	#category : 'HtmlSanitizer',
	#package : 'HtmlSanitizer'
}

{ #category : 'instance creation' }
HsNode class >> on: aPointer sanitizer: aSanitizer [

	^ self basicNew
		  setPointer: aPointer sanitizer: aSanitizer;
		  yourself
]

{ #category : 'private' }
HsNode >> setPointer: aPointer sanitizer: aSanitizer [

	pointer := aPointer.
	sanitizer := aSanitizer
]

{ #category : 'accessing' }
HsNode >> pointer [

	^ pointer
]

{ #category : 'private - ffi' }
HsNode >> ffiLibrary [

	^ HtmlSanitizerLibrary
]

{ #category : 'private - ffi' }
HsNode >> primKind: p [

	^ self ffiCall: #( int aether_hs_embed_node_kind ( void * p ) )
]

{ #category : 'private - ffi' }
HsNode >> primName: p [

	^ self ffiCall: #( void * aether_hs_embed_node_name ( void * p ) )
]

{ #category : 'private - ffi' }
HsNode >> primValue: p [

	^ self ffiCall: #( void * aether_hs_embed_node_value ( void * p ) )
]

{ #category : 'private - ffi' }
HsNode >> primChildCount: p [

	^ self ffiCall: #( int aether_hs_embed_node_child_count ( void * p ) )
]

{ #category : 'private - ffi' }
HsNode >> primChildAt: p index: i [

	^ self ffiCall: #( void * aether_hs_embed_node_child_at ( void * p, int i ) )
]

{ #category : 'private - ffi' }
HsNode >> primParent: p [

	^ self ffiCall: #( void * aether_hs_embed_node_parent ( void * p ) )
]

{ #category : 'private - ffi' }
HsNode >> primAttrCount: p [

	^ self ffiCall: #( int aether_hs_embed_node_attr_count ( void * p ) )
]

{ #category : 'private - ffi' }
HsNode >> primAttrAt: p index: i [

	^ self ffiCall: #( void * aether_hs_embed_node_attr_at ( void * p, int i ) )
]

{ #category : 'accessing' }
HsNode >> kindCode [
	"The raw ABI code: 1=Document, 2=Element, 3=Text, 4=Comment."

	^ self primKind: pointer
]

{ #category : 'accessing' }
HsNode >> kind [
	"#document, #element, #text, #comment, or #unknown."

	^ HtmlSanitizer nodeKindSymbolFor: self kindCode
]

{ #category : 'testing' }
HsNode >> isDocument [ ^ self kindCode = HtmlSanitizer nodeKindDocument ]

{ #category : 'testing' }
HsNode >> isElement [ ^ self kindCode = HtmlSanitizer nodeKindElement ]

{ #category : 'testing' }
HsNode >> isText [ ^ self kindCode = HtmlSanitizer nodeKindText ]

{ #category : 'testing' }
HsNode >> isComment [ ^ self kindCode = HtmlSanitizer nodeKindComment ]

{ #category : 'accessing' }
HsNode >> name [
	"Element tag name, lowercased by the parser; empty for non-elements."

	^ sanitizer takeString: (self primName: pointer)
]

{ #category : 'accessing' }
HsNode >> value [
	"Text/comment content; empty for elements and documents."

	^ sanitizer takeString: (self primValue: pointer)
]

{ #category : 'accessing' }
HsNode >> parent [
	"The parent node, or nil at the root."

	| p |
	p := self primParent: pointer.
	(p isNil or: [ p isNull ]) ifTrue: [ ^ nil ].
	^ HsNode on: p sanitizer: sanitizer
]

{ #category : 'accessing' }
HsNode >> children [
	"This node's children, as borrowed HsNodes."

	| n out |
	n := self primChildCount: pointer.
	out := OrderedCollection new.
	0 to: n - 1 do: [ :i |
		out add: (HsNode on: (self primChildAt: pointer index: i) sanitizer: sanitizer) ].
	^ out asArray
]

{ #category : 'accessing' }
HsNode >> attributes [
	"This node's attributes, as borrowed HsAttributes."

	| n out |
	n := self primAttrCount: pointer.
	out := OrderedCollection new.
	0 to: n - 1 do: [ :i |
		out add:
			(HsAttribute on: (self primAttrAt: pointer index: i) sanitizer: sanitizer) ].
	^ out asArray
]

{ #category : 'accessing' }
HsNode >> attributeNamed: aName [
	"The attribute with this name, or nil."

	^ self attributes detect: [ :a | a name = aName ] ifNone: [ nil ]
]

{ #category : 'enumerating' }
HsNode >> walk [
	"Depth-first Array of this node and its descendants, inclusive.

	 Built eagerly, not lazily: the DOM is freed when sanitize returns, so a
	 lazy walk forced afterwards would dereference freed memory."

	| out |
	out := OrderedCollection new.
	self walkInto: out.
	^ out asArray
]

{ #category : 'private' }
HsNode >> walkInto: aCollection [

	aCollection add: self.
	self children do: [ :each | each walkInto: aCollection ]
]

{ #category : 'converting' }
HsNode >> asDictionary [
	"A recursive, immutable snapshot: keys #kind #name #value #attributes
	 #children.

	 This is the safe way to keep anything about a node past its callback —
	 the HsNode itself becomes a dangling pointer the moment sanitize returns."

	^ Dictionary new
		  at: #kind put: self kind;
		  at: #name put: self name;
		  at: #value put: self value;
		  at: #attributes put: (self attributes collect: [ :a | a asDictionary ]);
		  at: #children put: (self children collect: [ :c | c asDictionary ]);
		  yourself
]

{ #category : 'printing' }
HsNode >> printOn: aStream [

	aStream
		nextPutAll: 'HsNode(';
		nextPutAll: self kind asString;
		nextPutAll: ' ''';
		nextPutAll: self name;
		nextPutAll: ''')'
]
