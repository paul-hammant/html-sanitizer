# frozen_string_literal: true

# The 12-check binding conformance suite (docs/conformance.md).
#
# Proves the Ruby binding marshals every value shape across the FFI. It is NOT
# a sanitizer test suite — the behavioural cases live in the sanitizer core's own tests
# and run once, in Aether.

require "htmlsanitizer"

RSpec.describe HtmlSanitizer do
  subject(:s) { HtmlSanitizer::Sanitizer.new }

  after { s.close unless s.closed? }

  it "01 removes a script element" do
    expect(s.sanitize("<div>Hello <script>alert(1)</script> world!</div>"))
      .to eq("<div>Hello  world!</div>")
  end

  it "02 removes an onclick attribute" do
    expect(s.sanitize('<div onclick="alert(1)">Hello</div>')).to eq("<div>Hello</div>")
  end

  it "03 round-trips the empty string" do
    expect(s.sanitize("")).to eq("")
  end

  it "04 round-trips UTF-8" do
    out = s.sanitize("<div>café ☕</div>")
    expect(out).to eq("<div>café ☕</div>")
    expect(out.encoding).to eq(Encoding::UTF_8)
  end

  it "05 allows a custom tag once added" do
    expect(s.sanitize("<my-widget>x</my-widget>")).to eq("")
    s.allowed_tags.add("my-widget")
    expect(s.sanitize("<my-widget>x</my-widget>")).to eq("<my-widget>x</my-widget>")
  end

  it "06 disallows a previously-allowed tag" do
    expect(s.sanitize("<div>x</div>")).to eq("<div>x</div>")
    s.allowed_tags.delete("div")
    expect(s.sanitize("<div>x</div>")).to eq("")
  end

  it "07 answers membership and count" do
    expect(s.allowed_schemes).to include("http")
    expect(s.allowed_schemes).not_to include("gopher")
    expect(s.allowed_schemes.size).to eq(2)
  end

  it "08 enumerates a policy list" do
    expect(s.allowed_schemes.to_a.sort).to eq(%w[http https])
  end

  it "09 honours keep_child_nodes" do
    expect(s.sanitize("<div><nope>Hello <span>world</span></nope></div>")).to eq("<div></div>")
    s.keep_child_nodes = true
    expect(s.keep_child_nodes).to be(true)
    expect(s.sanitize("<div><nope>Hello <span>world</span></nope></div>"))
      .to eq("<div>Hello <span>world</span></div>")
  end

  it "10 lets on_removing_tag cancel a removal" do
    seen = []
    s.on_removing_tag do |node, reason|
      seen << [node.name, reason]
      node.name == "keep-me"
    end

    out = s.sanitize("<div><keep-me>a</keep-me><drop-me>b</drop-me></div>")
    expect(out).to eq("<div><keep-me>a</keep-me></div>")
    expect(seen).to include(["keep-me", 0])
    expect(seen).to include(["drop-me", 0])
  end

  it "11 lets on_filter_url rewrite a resolved URL" do
    s.on_filter_url do |_node, _raw, resolved|
      resolved == "https://example.com/logo.png" ? "https://cdn.example.net/logo.png" : resolved
    end

    expect(s.sanitize('<img src="logo.png">', "https://example.com"))
      .to eq('<img src="https://cdn.example.net/logo.png">')
  end

  it "12 keeps handles independent" do
    HtmlSanitizer::Sanitizer.open do |a|
      HtmlSanitizer::Sanitizer.open do |b|
        a.allowed_tags.add("only-in-a")
        expect(a.allowed_tags).to include("only-in-a")
        expect(b.allowed_tags).not_to include("only-in-a")
      end
    end
  end

  # ---- a few extras that exercise the remaining callback shapes ----

  it "shows the attribute to on_removing_attribute" do
    seen = []
    s.on_removing_attribute do |elem, attr, _reason|
      seen << [elem.name, attr.name, attr.value]
      false
    end

    expect(s.sanitize('<div onclick="alert(1)">x</div>')).to eq("<div>x</div>")
    expect(seen).to include(%w[div onclick alert(1)])
  end

  it "lets on_removing_comment cancel a removal" do
    s.on_removing_comment { |_node| true }
    expect(s.sanitize("<div>a<!-- keep -->b</div>")).to eq("<div>a<!-- keep -->b</div>")
  end

  it "passes four arguments to on_removing_style" do
    seen = []
    s.on_removing_style do |_elem, name, value, _reason|
      seen << [name, value]
      name == "-custom-thing"
    end

    out = s.sanitize('<div style="-custom-thing: 3; color: red">x</div>')
    expect(out).to include("-custom-thing")
    expect(seen).to include(["-custom-thing", "3"])
  end

  it "visits nodes in on_post_process_node" do
    kinds = []
    s.on_post_process_node { |node| kinds << node.kind }
    s.sanitize("<div><span>a</span><span>b</span></div>")
    expect(kinds).not_to be_empty
  end

  it "navigates the node tree from on_post_process_dom" do
    captured = {}
    s.on_post_process_dom do |doc|
      captured[:kind] = doc.kind
      captured[:children] = doc.children.size
    end

    s.sanitize("<div>a</div><p>b</p>")
    expect(captured[:kind]).to eq(HtmlSanitizer::Node::DOCUMENT)
    expect(captured[:children]).to be >= 2
  end

  it "reports an ABI version" do
    expect(s.abi_version).to be >= 1
  end

  it "rejects use after close" do
    sanitizer = HtmlSanitizer::Sanitizer.new
    sanitizer.close
    expect { sanitizer.sanitize("<div>x</div>") }.to raise_error(HtmlSanitizer::ClosedError)
  end

  # ---- surface sugar unique to the Ruby binding ----

  it "sanitizes via the module-level shorthand" do
    expect(HtmlSanitizer.sanitize("<div>a<script>b</script></div>")).to eq("<div>a</div>")
  end

  it "sanitizes a whole document" do
    expect(s.sanitize_document("<div>doc<script>x</script></div>")).to eq("<html><head></head><body><div>doc</div></body></html>")
  end

  it "honours allow_data_attributes" do
    s.allow_data_attributes = true
    expect(s.allow_data_attributes).to be(true)
    expect(s.sanitize('<div data-x="1"></div>')).to eq('<div data-x="1"></div>')
  end

  it "clears a policy list" do
    s.allowed_schemes.clear
    expect(s.allowed_schemes.size).to eq(0)
    expect(s.allowed_schemes).to be_empty
  end

  it "rewrites an attribute value from a callback" do
    s.on_removing_attribute do |_elem, attr, _reason|
      attr.value = "scrubbed"
      false
    end
    expect(s.sanitize('<div onclick="alert(1)">x</div>')).to eq("<div>x</div>")
  end
end
