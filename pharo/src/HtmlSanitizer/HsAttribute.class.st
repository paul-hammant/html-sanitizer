"
I am a DOM attribute, **borrowed** for the duration of one callback.

Do not retain me past the callback that gave me to you: the DOM is freed when
`sanitize` returns. Use `asDictionary` to snapshot instead.

I carry no sanitizer logic. Every accessor is one `aether_hs_embed_attr_*`
call, made through the sanitizer that owns the DOM.
"
Class {
	#name : 'HsAttribute',
	#superclass : 'Object',
	#instVars : [ 'pointer', 'sanitizer' ],
	#category : 'HtmlSanitizer',
	#package : 'HtmlSanitizer'
}

{ #category : 'instance creation' }
HsAttribute class >> on: aPointer sanitizer: aSanitizer [

	^ self basicNew
		  setPointer: aPointer sanitizer: aSanitizer;
		  yourself
]

{ #category : 'private' }
HsAttribute >> setPointer: aPointer sanitizer: aSanitizer [

	pointer := aPointer.
	sanitizer := aSanitizer
]

{ #category : 'accessing' }
HsAttribute >> pointer [

	^ pointer
]

{ #category : 'private - ffi' }
HsAttribute >> ffiLibrary [

	^ HtmlSanitizerLibrary
]

{ #category : 'private - ffi' }
HsAttribute >> primName: p [

	^ self ffiCall: #( void * aether_hs_embed_attr_name ( void * p ) )
]

{ #category : 'private - ffi' }
HsAttribute >> primValue: p [

	^ self ffiCall: #( void * aether_hs_embed_attr_value ( void * p ) )
]

{ #category : 'private - ffi' }
HsAttribute >> primSetValue: p to: v [

	^ self ffiCall: #( void aether_hs_embed_attr_set_value ( void * p, void * v ) )
]

{ #category : 'accessing' }
HsAttribute >> name [

	^ sanitizer takeString: (self primName: pointer)
]

{ #category : 'accessing' }
HsAttribute >> value [

	^ sanitizer takeString: (self primValue: pointer)
]

{ #category : 'accessing' }
HsAttribute >> value: aString [
	"Rewrite this attribute's value in place — e.g. to canonicalise a URL
	 rather than let the attribute be removed.

	 OWNERSHIP: the ABI stores the pointer we pass straight INTO the DOM
	 (`at.value = value` in core/embed.ae) rather than copying it, so the
	 buffer must outlive this call and must be freeable by libc. A
	 libc-malloc'd copy is what the sanitizer core expects, and it is not freed here:
	 the sanitizer core owns it once stored, the same contract as on_filter_url's
	 return value."

	self primSetValue: pointer to: (sanitizer mallocString: aString).
	^ self
]

{ #category : 'converting' }
HsAttribute >> asDictionary [
	"An immutable snapshot: keys #name and #value. Safe to keep past the
	 callback, which this HsAttribute is not."

	^ Dictionary new
		  at: #name put: self name;
		  at: #value put: self value;
		  yourself
]

{ #category : 'printing' }
HsAttribute >> printOn: aStream [

	aStream
		nextPutAll: 'HsAttribute(';
		nextPutAll: self name;
		nextPutAll: '=''';
		nextPutAll: self value;
		nextPutAll: ''')'
]
