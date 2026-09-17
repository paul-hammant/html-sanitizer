# Package manifest for the Nim binding.
#
# Note this package LINKS the native sanitizer core (see src/htmlsanitizer.nim's
# {.passL.}), so `libhtmlsanitizer.so` must be present at COMPILE time, not
# just at run time. `nim/.tests.ae` stages it into nim/native/; an in-tree
# checkout also has core/native/libhtmlsanitizer.so, and both directories are
# on the link path and baked in as rpath.
#
# There is no `requires` beyond nim itself: a binding that marshals to a C ABI
# needs no third-party code, which keeps `nimble install` offline and keeps the
# dependency surface of a security-relevant library at zero.

version       = "0.1.0"
author        = "Paul Hammant"
description   = "Clean HTML of constructs that can lead to XSS — a thin binding over the shared native sanitizer core"
license       = "MIT"
srcDir        = "src"

requires "nim >= 1.6.0"

# `nimble test` compiles and runs every tests/t*.nim. The suite is equally
# runnable without nimble, which is how .tests.ae drives it:
#
#     nim c -r tests/tconformance.nim
task test, "Run the 12-check conformance suite":
  exec "nim c -r --hints:off tests/tconformance.nim"
