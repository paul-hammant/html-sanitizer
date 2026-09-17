# frozen_string_literal: true

# htmlsanitizer — clean HTML of XSS vectors.
#
# A thin Fiddle binding over ONE shared native sanitizer core
# (core/native/libhtmlsanitizer.so, built from pure Aether). No sanitizer
# logic lives in this gem; it only marshals values across the C ABI.
#
#     require "htmlsanitizer"
#
#     s = HtmlSanitizer.new
#     s.sanitize('<div onclick="alert(1)">hi</div>')  # => "<div>hi</div>"
#     s.close

require_relative "htmlsanitizer/version"
require_relative "htmlsanitizer/native"
require_relative "htmlsanitizer/sanitizer"

module HtmlSanitizer
  class << self
    # HtmlSanitizer.new is a shorthand for HtmlSanitizer::Sanitizer.new; with a
    # block it closes the handle for you.
    def new(native_lib: nil, &blk)
      Sanitizer.open(native_lib: native_lib, &blk)
    end

    # One-shot convenience: sanitize a fragment with the secure defaults.
    def sanitize(html, base_url = "", native_lib: nil)
      new(native_lib: native_lib) { |s| s.sanitize(html, base_url) }
    end

    # One-shot convenience for a whole document.
    def sanitize_document(html, base_url = "", native_lib: nil)
      new(native_lib: native_lib) { |s| s.sanitize_document(html, base_url) }
    end

    # The sanitizer core's ABI revision.
    def abi_version
      new { |s| s.abi_version }
    end
  end
end
