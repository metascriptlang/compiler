import { assertFmtPreservesAst, assertFmtIdempotent, fmt } from "../roundtrip";
import { NodeKind, createNodeAt, makeLoc } from "../../../ast/node";
import { formatNode } from "../../../compiler/fmt/printer/index";
import { defaultFormatOptions } from "../../../compiler/fmt/options";

const REPRO = "function f(title: string): Node {\n\treturn <view style={{ padding: 8 }}><text>{title}</text></view>;\n}\n";

const ATTRS = "const a = <input disabled value=\"x\" label='y' xlink:href=\"u\" on={true} {...rest} n={1 + 2} />;\n";

const FRAGMENT = "const f = <><a/>text<b>{x}</b></>;\n";

const NESTED = "const n = <A.B>\n\t<c>\n\t\t<d k={1}>deep {v} text</d>\n\t</c>\n</A.B>;\n";

const ATTR_JSX = "const p = <list render={<row x=\"1\"><cell/></row>} />;\n";

const LONG_ATTRS = "const l = <panel title=\"a fairly long title value\" subtitle=\"another long value\" onClose={handleCloseOfThePanel}>body</panel>;\n";

test "fmt jsx: repro element with object attribute and expression child round-trips" {
	assert assertFmtPreservesAst(REPRO);
	assert assertFmtIdempotent(REPRO);
}

test "fmt jsx: string, bare, namespaced, spread and expression attributes round-trip" {
	assert assertFmtPreservesAst(ATTRS);
	assert assertFmtIdempotent(ATTRS);
}

test "fmt jsx: fragment with mixed children round-trips" {
	assert assertFmtPreservesAst(FRAGMENT);
	assert assertFmtIdempotent(FRAGMENT);
}

test "fmt jsx: three levels of nesting keep their whitespace text verbatim" {
	assert assertFmtPreservesAst(NESTED);
	assert assertFmtIdempotent(NESTED);
}

test "fmt jsx: element in attribute position round-trips" {
	assert assertFmtPreservesAst(ATTR_JSX);
	assert assertFmtIdempotent(ATTR_JSX);
}

test "fmt jsx: attributes that overflow the line break without touching children" {
	assert assertFmtPreservesAst(LONG_ATTRS);
	assert assertFmtIdempotent(LONG_ATTRS);
}

test "fmt jsx: bare attribute stays bare and braced true stays braced" {
	assert fmt("const a = <input disabled on={true}/>;\n").contains("<input disabled on={true} />");
}

test "fmt fails loud on a node kind it cannot print" {
	const inner = createNodeAt(NodeKind.Identifier, { name: "x" }, makeLoc(1, 1));
	const hidden = createNodeAt(NodeKind.HiddenDeref, { expr: inner }, makeLoc(1, 1));
	assert !formatNode(hidden, defaultFormatOptions()).ok;
}
