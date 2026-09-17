"
I am the FFI library handle for the shared HtmlSanitizer core.

I am the ONLY class in this package that knows where the shared library lives.
Everything else reaches the sanitizer core through `HtmlSanitizer`, which sends its
FFI calls with `self ffiLibrary: HtmlSanitizerLibrary`.

## The sanitizer core

No sanitizer logic lives in this package. The sanitizer core — HTML5 tokenizer, DOM,
CSS parser, URL resolver, allow-lists — is the pure-Aether
`core/htmlsanitizer.ae`, shared by every language binding in this monorepo and
reached through the `aether_hs_embed_*` C ABI (`core/embed.ae`).

Unlike the Kotlin/Scala/Clojure/Groovy layers, which sit on the Java binding,
this IS a real FFI: Pharo is not a JVM, so it binds the C ABI directly with
UnifiedFFI.

## Resolution order

Matching every other binding in the monorepo:

1. an explicit path — `HtmlSanitizerLibrary explicitPath: '/path/to/lib.so'`
2. `$HTMLSANITIZER_LIB`
3. `native/` beside the image
4. the OS loader's own search path
"
Class {
	#name : 'HtmlSanitizerLibrary',
	#superclass : 'FFILibrary',
	#classVars : [ 'ExplicitPath' ],
	#category : 'HtmlSanitizer',
	#package : 'HtmlSanitizer'
}

{ #category : 'accessing' }
HtmlSanitizerLibrary class >> explicitPath [
	"An explicit sanitizer core path, or nil to use the usual search."

	^ ExplicitPath
]

{ #category : 'accessing' }
HtmlSanitizerLibrary class >> explicitPath: aStringOrNil [
	"Pin the sanitizer core to one path. Pass nil to go back to the usual search.
	 Set this BEFORE the first FFI call: UnifiedFFI caches the resolved
	 handle, so a later change does not move an already-bound session."

	ExplicitPath := aStringOrNil
]

{ #category : 'accessing' }
HtmlSanitizerLibrary class >> libraryName [

	^ self new libraryName
]

{ #category : 'accessing - platform' }
HtmlSanitizerLibrary >> macModuleName [

	^ self resolvedPathFor: 'libhtmlsanitizer.dylib'
]

{ #category : 'accessing - platform' }
HtmlSanitizerLibrary >> unix64ModuleName [

	^ self resolvedPathFor: 'libhtmlsanitizer.so'
]

{ #category : 'accessing - platform' }
HtmlSanitizerLibrary >> unixModuleName [

	^ self resolvedPathFor: 'libhtmlsanitizer.so'
]

{ #category : 'accessing - platform' }
HtmlSanitizerLibrary >> win32ModuleName [

	^ self resolvedPathFor: 'htmlsanitizer.dll'
]

{ #category : 'private' }
HtmlSanitizerLibrary >> resolvedPathFor: aFileName [
	"The sanitizer core's path, by the monorepo's standard resolution order. Falls
	 back to the bare file name, which lets the OS loader search its own
	 paths — so a system-installed sanitizer core still works."

	| explicit env bundled |
	explicit := self class explicitPath.
	(explicit isNil or: [ explicit isEmpty ]) ifFalse: [ ^ explicit ].

	env := OSEnvironment current at: 'HTMLSANITIZER_LIB' ifAbsent: [ nil ].
	(env isNil or: [ env isEmpty ]) ifFalse: [ ^ env ].

	bundled := FileLocator imageDirectory / 'native' / aFileName.
	bundled exists ifTrue: [ ^ bundled fullName ].

	^ aFileName
]
