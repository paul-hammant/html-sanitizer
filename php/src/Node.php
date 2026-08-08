<?php

declare(strict_types=1);

namespace HtmlSanitization;

use FFI;

/**
 * A DOM node, **borrowed** for the duration of a callback.
 */
final class Node
{
    /** @param FFI\CData $ptr */
    public function __construct(private FFI $ffi, private $ptr)
    {
    }

    /** One of Native::NODE_DOCUMENT | NODE_ELEMENT | NODE_TEXT | NODE_COMMENT. */
    public function kind(): int
    {
        return $this->ffi->aether_hs_embed_node_kind($this->ptr);
    }

    /** Element tag name, lowercased by the parser; "" for non-elements. */
    public function name(): string
    {
        return Native::takeString($this->ffi, $this->ffi->aether_hs_embed_node_name($this->ptr));
    }

    /** Text/comment content; "" for elements and documents. */
    public function value(): string
    {
        return Native::takeString($this->ffi, $this->ffi->aether_hs_embed_node_value($this->ptr));
    }

    public function parent(): ?Node
    {
        $p = $this->ffi->aether_hs_embed_node_parent($this->ptr);
        return FFI::isNull($p) ? null : new Node($this->ffi, $p);
    }

    public function childCount(): int
    {
        return $this->ffi->aether_hs_embed_node_child_count($this->ptr);
    }

    public function childAt(int $index): ?Node
    {
        $p = $this->ffi->aether_hs_embed_node_child_at($this->ptr, $index);
        return FFI::isNull($p) ? null : new Node($this->ffi, $p);
    }

    /** @return list<Node> */
    public function children(): array
    {
        $out = [];
        $n = $this->childCount();
        for ($i = 0; $i < $n; $i++) {
            $child = $this->childAt($i);
            if ($child !== null) {
                $out[] = $child;
            }
        }
        return $out;
    }

    public function attributeCount(): int
    {
        return $this->ffi->aether_hs_embed_node_attr_count($this->ptr);
    }

    public function attributeAt(int $index): ?Attribute
    {
        $p = $this->ffi->aether_hs_embed_node_attr_at($this->ptr, $index);
        return FFI::isNull($p) ? null : new Attribute($this->ffi, $p);
    }

    /** @return list<Attribute> */
    public function attributes(): array
    {
        $out = [];
        $n = $this->attributeCount();
        for ($i = 0; $i < $n; $i++) {
            $attr = $this->attributeAt($i);
            if ($attr !== null) {
                $out[] = $attr;
            }
        }
        return $out;
    }

    public function __toString(): string
    {
        return sprintf('Node(kind=%d, name=%s)', $this->kind(), $this->name());
    }
}
