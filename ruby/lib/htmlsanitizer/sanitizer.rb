# frozen_string_literal: true

# Idiomatic Ruby surface over the HtmlSanitizer core.
#
# Carries no sanitizer logic — see the monorepo's one rule in LLM.md. Every
# method here marshals to an `aether_hs_embed_*` call in `native.rb`.

require_relative "native"

module HtmlSanitizer
  # A DOM attribute, borrowed for the duration of a callback.
  #
  # Do not retain one past the callback that gave it to you — the DOM is freed
  # when sanitize returns.
  class Attribute
    def initialize(lib, ptr)
      @lib = lib
      @ptr = ptr
    end

    def name
      @lib.take_string(@lib.call("aether_hs_embed_attr_name", @ptr))
    end

    def value
      @lib.take_string(@lib.call("aether_hs_embed_attr_value", @ptr))
    end

    def value=(v)
      @lib.call("aether_hs_embed_attr_set_value", @ptr, (v || "").to_s)
      v
    end

    def inspect
      "#<HtmlSanitizer::Attribute #{name.inspect}=#{value.inspect}>"
    end
  end

  # A DOM node, borrowed for the duration of a callback.
  class Node
    DOCUMENT = Native::NODE_DOCUMENT
    ELEMENT  = Native::NODE_ELEMENT
    TEXT     = Native::NODE_TEXT
    COMMENT  = Native::NODE_COMMENT

    def initialize(lib, ptr)
      @lib = lib
      @ptr = ptr
    end

    def kind
      @lib.call("aether_hs_embed_node_kind", @ptr)
    end

    def name
      @lib.take_string(@lib.call("aether_hs_embed_node_name", @ptr))
    end

    def value
      @lib.take_string(@lib.call("aether_hs_embed_node_value", @ptr))
    end

    def document? = kind == DOCUMENT
    def element?  = kind == ELEMENT
    def text?     = kind == TEXT
    def comment?  = kind == COMMENT

    def parent
      p = @lib.call("aether_hs_embed_node_parent", @ptr)
      Native.null?(p) ? nil : Node.new(@lib, p)
    end

    def children
      n = @lib.call("aether_hs_embed_node_child_count", @ptr)
      Array.new(n) do |i|
        Node.new(@lib, @lib.call("aether_hs_embed_node_child_at", @ptr, i))
      end
    end

    def attributes
      n = @lib.call("aether_hs_embed_node_attr_count", @ptr)
      Array.new(n) do |i|
        Attribute.new(@lib, @lib.call("aether_hs_embed_node_attr_at", @ptr, i))
      end
    end

    def inspect
      "#<HtmlSanitizer::Node kind=#{kind} name=#{name.inspect}>"
    end
  end

  # Set-like view over one of the sanitizer core's six policy lists.
  class AllowList
    include Enumerable

    def initialize(owner, which)
      @owner = owner
      @which = which
    end

    def add(item)
      @owner.__call("aether_hs_embed_allow", @which, item.to_s)
      self
    end
    alias << add

    def merge(items)
      items.each { |i| add(i) }
      self
    end
    alias update merge

    def delete(item)
      @owner.__call("aether_hs_embed_disallow", @which, item.to_s)
      self
    end
    alias discard delete

    def clear
      @owner.__call("aether_hs_embed_clear", @which)
      self
    end

    def include?(item)
      @owner.__call("aether_hs_embed_is_allowed", @which, item.to_s) != 0
    end
    alias member? include?

    def size
      @owner.__call("aether_hs_embed_count", @which)
    end
    alias length size
    alias count size

    def each
      return enum_for(:each) unless block_given?

      size.times do |i|
        yield @owner.__take_string(
          @owner.__call("aether_hs_embed_item_at", @which, i)
        )
      end
      self
    end

    def to_a = each.to_a
    def to_set = require("set") && Set.new(to_a)
    def empty? = size.zero?

    def inspect
      "#<HtmlSanitizer::AllowList {#{sort.map(&:inspect).join(', ')}}>"
    end
  end

  # Cleans HTML of constructs that can lead to XSS.
  #
  #     s = HtmlSanitizer::Sanitizer.new
  #     s.allowed_tags.add("my-widget")
  #     clean = s.sanitize('<div onclick="evil()">hi</div>')
  #
  # Usable with a block (auto-closing); otherwise call #close to release the
  # native handle.
  class Sanitizer
    attr_reader :allowed_tags, :allowed_attributes, :allowed_css_properties,
                :allowed_schemes, :allowed_classes, :uri_attributes

    def self.open(native_lib: nil)
      s = new(native_lib: native_lib)
      return s unless block_given?

      begin
        yield s
      ensure
        s.close
      end
    end

    def initialize(native_lib: nil)
      @lib = Native.load(native_lib)
      @h = @lib.call("aether_hs_embed_new")
      raise "failed to create the native sanitizer" if Native.null?(@h)

      # Fiddle closures must be kept alive for as long as the sanitizer core can call
      # them — a local trampoline would be GC'd and crash the process.
      @keepalive = []

      @allowed_tags           = AllowList.new(self, Native::TAGS)
      @allowed_attributes     = AllowList.new(self, Native::ATTRIBUTES)
      @allowed_css_properties = AllowList.new(self, Native::CSS_PROPERTIES)
      @allowed_schemes        = AllowList.new(self, Native::SCHEMES)
      @allowed_classes        = AllowList.new(self, Native::CLASSES)
      @uri_attributes         = AllowList.new(self, Native::URI_ATTRIBUTES)
    end

    # ---- lifecycle ----

    def close
      return if @h.nil?

      @lib.call("aether_hs_embed_free", @h)
      @h = nil
      @keepalive = []
      nil
    end

    def closed? = @h.nil?

    # ---- the main entry point ----

    def sanitize(html, base_url = "")
      check!
      @lib.take_string(
        @lib.call("aether_hs_embed_sanitize", @h, (html || "").to_s, (base_url || "").to_s)
      )
    end

    def sanitize_document(html, base_url = "")
      check!
      @lib.take_string(
        @lib.call("aether_hs_embed_sanitize_document", @h, (html || "").to_s, (base_url || "").to_s)
      )
    end

    # ---- flags ----

    def keep_child_nodes
      @lib.call("aether_hs_embed_get_keep_child_nodes", @h) != 0
    end
    alias keep_child_nodes? keep_child_nodes

    def keep_child_nodes=(on)
      @lib.call("aether_hs_embed_set_keep_child_nodes", @h, on ? 1 : 0)
      on
    end

    def allow_data_attributes
      @lib.call("aether_hs_embed_get_allow_data_attributes", @h) != 0
    end
    alias allow_data_attributes? allow_data_attributes

    def allow_data_attributes=(on)
      @lib.call("aether_hs_embed_set_allow_data_attributes", @h, on ? 1 : 0)
      on
    end

    def abi_version
      @lib.call("aether_hs_embed_abi_version")
    end

    # ---- callbacks ----
    #
    # Each `on_*` takes a block (or any callable) and returns self, so they
    # chain. Passing nil clears the hook. For the `removing_*` family,
    # returning true from your handler CANCELS the removal (keeps the node);
    # returning false/nil lets it proceed.

    def on_removing_tag(handler = nil, &blk)
      install("aether_hs_embed_on_removing_tag", handler || blk, Native::CB_REMOVING_TAG) do |fn|
        proc do |_ud, node, reason|
          fn.call(Node.new(@lib, node), reason) ? 1 : 0
        end
      end
    end

    def on_removing_attribute(handler = nil, &blk)
      install("aether_hs_embed_on_removing_attribute", handler || blk,
              Native::CB_REMOVING_ATTRIBUTE) do |fn|
        proc do |_ud, elem, attr, reason|
          fn.call(Node.new(@lib, elem), Attribute.new(@lib, attr), reason) ? 1 : 0
        end
      end
    end

    def on_removing_style(handler = nil, &blk)
      install("aether_hs_embed_on_removing_style", handler || blk,
              Native::CB_REMOVING_STYLE) do |fn|
        proc do |_ud, elem, name, value, reason|
          fn.call(Node.new(@lib, elem), Native.read_string(name),
                  Native.read_string(value), reason) ? 1 : 0
        end
      end
    end

    def on_removing_comment(handler = nil, &blk)
      install("aether_hs_embed_on_removing_comment", handler || blk,
              Native::CB_REMOVING_COMMENT) do |fn|
        proc do |_ud, node|
          fn.call(Node.new(@lib, node)) ? 1 : 0
        end
      end
    end

    def on_post_process_node(handler = nil, &blk)
      install("aether_hs_embed_on_post_process_node", handler || blk,
              Native::CB_POST_PROCESS) do |fn|
        proc do |_ud, node|
          fn.call(Node.new(@lib, node))
          nil
        end
      end
    end

    def on_post_process_dom(handler = nil, &blk)
      install("aether_hs_embed_on_post_process_dom", handler || blk,
              Native::CB_POST_PROCESS) do |fn|
        proc do |_ud, doc|
          fn.call(Node.new(@lib, doc))
          nil
        end
      end
    end

    # handler(node, raw_url, resolved_url) -> String
    #
    # Return the URL to use ("" drops the attribute). The returned string is
    # copied into a C buffer the sanitizer core takes ownership of.
    def on_filter_url(handler = nil, &blk)
      install("aether_hs_embed_on_filter_url", handler || blk,
              Native::CB_FILTER_URL) do |fn|
        proc do |_ud, elem, raw, resolved|
          out = fn.call(Node.new(@lib, elem), Native.read_string(raw),
                        Native.read_string(resolved))
          Native.strdup(out.nil? ? "" : out.to_s)
        end
      end
    end

    def inspect
      "#<HtmlSanitizer::Sanitizer#{closed? ? ' (closed)' : ''}>"
    end

    # ---- internals used by AllowList (not part of the public surface) ----

    def __call(name, *args)
      check!
      @lib.call(name, @h, *args)
    end

    def __take_string(ptr) = @lib.take_string(ptr)

    private

    def check!
      raise ClosedError, "sanitizer is closed" if @h.nil?
    end

    def install(register, handler, (argtypes, restype))
      check!
      if handler.nil?
        @lib.call(register, @h, nil, nil)
        return self
      end

      impl = yield(handler)
      closure = Fiddle::Closure::BlockCaller.new(restype, argtypes, &impl)
      @keepalive << closure
      @lib.call(register, @h, closure, nil)
      self
    end
  end

  # Raised when a closed sanitizer is used.
  class ClosedError < RuntimeError; end
end
