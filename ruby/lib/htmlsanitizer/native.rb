# frozen_string_literal: true

# Fiddle bindings for the HtmlSanitizer core (libhtmlsanitizer.so).
#
# This file is the ONLY place in the Ruby binding that knows about the C ABI.
# Everything above it (`sanitizer.rb`) is idiomatic Ruby over these symbols.
# No sanitizer logic lives here or anywhere else in this gem — the sanitizer core is
# `core/htmlsanitizer.ae`, shared by every language binding.
#
# Library resolution, in order:
#   1. an explicit path passed to `Native.load(path)` /
#      `HtmlSanitizer::Sanitizer.new(native_lib: ...)`
#   2. $HTMLSANITIZER_LIB          (what the in-tree .tests.ae leaves set)
#   3. native/ bundled next to this gem's lib dir (what a built gem ships)
#   4. the OS loader's own search path

require "fiddle"
require "fiddle/import"
require "rbconfig"

module HtmlSanitizer
  # Low-level FFI seam. Everything here mirrors core/embed.ae one-for-one.
  module Native
    LIB_NAME =
      case RbConfig::CONFIG["host_os"]
      when /darwin/ then "libhtmlsanitizer.dylib"
      when /mswin|mingw|cygwin/ then "htmlsanitizer.dll"
      else "libhtmlsanitizer.so"
      end

    # ---- allow-list selectors (ABI constants — append only, never renumber) --
    TAGS = 0
    ATTRIBUTES = 1
    CSS_PROPERTIES = 2
    SCHEMES = 3
    CLASSES = 4
    URI_ATTRIBUTES = 5

    # ---- removal reasons, as passed to the callbacks ----
    REASON_NOT_ALLOWED_TAG = 0
    REASON_NOT_ALLOWED_ATTRIBUTE = 1
    REASON_NOT_ALLOWED_STYLE = 2
    REASON_NOT_ALLOWED_URL_VALUE = 3
    REASON_NOT_ALLOWED_VALUE = 4
    REASON_NOT_ALLOWED_CSS_CLASS = 5
    REASON_CLASS_ATTRIBUTE_EMPTY = 6
    REASON_STYLE_ATTRIBUTE_EMPTY = 7

    # ---- node kinds ----
    NODE_DOCUMENT = 1
    NODE_ELEMENT = 2
    NODE_TEXT = 3
    NODE_COMMENT = 4

    P = Fiddle::TYPE_VOIDP
    I = Fiddle::TYPE_INT
    V = Fiddle::TYPE_VOID

    # name => [argtypes, restype].
    #
    # Every string-returning symbol is declared as TYPE_VOIDP, not
    # Fiddle::TYPE_CONST_STRING: the pointer is caller-owned and has to come
    # back through aether_hs_embed_free_string. Letting Fiddle turn it into a
    # Ruby String directly would lose the pointer and leak the buffer.
    SIGS = {
      "aether_hs_embed_new" => [[], P],
      "aether_hs_embed_free" => [[P], V],
      "aether_hs_embed_free_string" => [[P], V],
      "aether_hs_embed_sanitize" => [[P, P, P], P],
      "aether_hs_embed_sanitize_document" => [[P, P, P], P],
      "aether_hs_embed_set_keep_child_nodes" => [[P, I], V],
      "aether_hs_embed_get_keep_child_nodes" => [[P], I],
      "aether_hs_embed_set_allow_data_attributes" => [[P, I], V],
      "aether_hs_embed_get_allow_data_attributes" => [[P], I],
      "aether_hs_embed_allow" => [[P, I, P], I],
      "aether_hs_embed_disallow" => [[P, I, P], I],
      "aether_hs_embed_is_allowed" => [[P, I, P], I],
      "aether_hs_embed_clear" => [[P, I], I],
      "aether_hs_embed_count" => [[P, I], I],
      "aether_hs_embed_item_at" => [[P, I, I], P],
      "aether_hs_embed_abi_version" => [[], I],
      "aether_hs_embed_on_removing_tag" => [[P, P, P], V],
      "aether_hs_embed_on_removing_attribute" => [[P, P, P], V],
      "aether_hs_embed_on_removing_style" => [[P, P, P], V],
      "aether_hs_embed_on_removing_comment" => [[P, P, P], V],
      "aether_hs_embed_on_post_process_node" => [[P, P, P], V],
      "aether_hs_embed_on_post_process_dom" => [[P, P, P], V],
      "aether_hs_embed_on_filter_url" => [[P, P, P], V],
      "aether_hs_embed_node_kind" => [[P], I],
      "aether_hs_embed_node_name" => [[P], P],
      "aether_hs_embed_node_value" => [[P], P],
      "aether_hs_embed_node_child_count" => [[P], I],
      "aether_hs_embed_node_child_at" => [[P, I], P],
      "aether_hs_embed_node_parent" => [[P], P],
      "aether_hs_embed_node_attr_count" => [[P], I],
      "aether_hs_embed_node_attr_at" => [[P, I], P],
      "aether_hs_embed_attr_name" => [[P], P],
      "aether_hs_embed_attr_value" => [[P], P],
      "aether_hs_embed_attr_set_value" => [[P, P], V]
    }.freeze

    # ---- callback prototypes ----
    # Each takes an opaque user_data first; the sanitizer core's trampoline supplies it.
    CB_REMOVING_TAG       = [[P, P, I], I].freeze
    CB_REMOVING_ATTRIBUTE = [[P, P, P, I], I].freeze
    CB_REMOVING_STYLE     = [[P, P, P, P, I], I].freeze
    CB_REMOVING_COMMENT   = [[P, P], I].freeze
    CB_POST_PROCESS       = [[P, P], V].freeze
    CB_FILTER_URL         = [[P, P, P, P], P].freeze

    # A loaded sanitizer core: the Fiddle::Handle plus a memoized Fiddle::Function per
    # exported symbol. `fn[:aether_hs_embed_sanitize].call(...)` is the whole
    # calling convention.
    class Lib
      attr_reader :path

      def initialize(path)
        @path = path
        @handle = Fiddle.dlopen(path)
        @fns = {}
        Native::SIGS.each do |name, (argtypes, restype)|
          @fns[name] = Fiddle::Function.new(@handle[name], argtypes, restype)
        rescue Fiddle::DLError => e
          raise Fiddle::DLError, "missing symbol #{name} in #{path}: #{e.message}"
        end
      end

      def call(name, *args)
        (@fns[name] || raise(ArgumentError, "unknown ABI symbol #{name}")).call(*args)
      end

      # Copy an ABI-returned string out and free it through the ABI.
      #
      # Every char* the sanitizer core returns is caller-owned; leaking it is the
      # single easiest mistake to make in any of these bindings.
      def take_string(ptr)
        return "" if ptr.nil?
        return "" if ptr.is_a?(Integer) && ptr.zero?
        p = ptr.is_a?(Fiddle::Pointer) ? ptr : Fiddle::Pointer.new(ptr)
        return "" if p.null?

        begin
          p.to_s.force_encoding(Encoding::UTF_8)
        ensure
          call("aether_hs_embed_free_string", p)
        end
      end
    end

    class << self
      # Load the sanitizer core .so, caching it process-wide. Returns a Lib.
      def load(path = nil)
        return @lib if @lib && path.nil?

        last = nil
        lib = nil
        candidates(path).each do |cand|
          begin
            lib = Lib.new(cand)
            break
          rescue Fiddle::DLError => e
            last = e
          end
        end
        if lib.nil?
          raise Fiddle::DLError,
                "could not load the HtmlSanitizer core (#{LIB_NAME}). Set " \
                "HTMLSANITIZER_LIB to its absolute path, or install a gem that " \
                "bundles it. Last error: #{last}"
        end

        @lib = lib if path.nil?
        lib
      end

      def candidates(explicit = nil)
        return [explicit] if explicit && !explicit.empty?

        out = []
        env = ENV["HTMLSANITIZER_LIB"]
        out << env if env && !env.empty?
        here = File.dirname(File.expand_path(__dir__)) # ruby/lib
        out << File.join(here, "..", "native", LIB_NAME)
        out << File.join(here, "htmlsanitizer", "native", LIB_NAME)
        out << LIB_NAME
        out
      end

      # Duplicate a Ruby string into a malloc'd C buffer the callee owns.
      # Used by the filter_url hook, whose return value the sanitizer core frees.
      def strdup(str)
        bytes = (str || "").to_s.dup.force_encoding(Encoding::BINARY)
        buf = Fiddle::Pointer.malloc(bytes.bytesize + 1, nil)
        buf[0, bytes.bytesize] = bytes
        buf[bytes.bytesize] = 0
        buf
      end

      # Read a `const char*` callback argument into a Ruby String.
      def read_string(ptr)
        return "" if ptr.nil?
        return "" if ptr.is_a?(Integer) && ptr.zero?

        p = ptr.is_a?(Fiddle::Pointer) ? ptr : Fiddle::Pointer.new(ptr)
        return "" if p.null?

        p.to_s.force_encoding(Encoding::UTF_8)
      end

      # Nil out a pointer-ish value so callbacks can hand `nil` upward.
      def null?(ptr)
        return true if ptr.nil?
        return true if ptr.is_a?(Integer) && ptr.zero?

        ptr.is_a?(Fiddle::Pointer) ? ptr.null? : false
      end
    end
  end
end
