// bug601 — a down-conversion was an unchecked reinterpret, and instanceof failed on C
//
// Symptom:    `(n as NativeNode).view` on a DomNode read the other class's memory on C
//             and gave `undefined` on JS; `if (n instanceof NativeNode) n.view` did not
//             compile on C; `u as I` for an interface I and `u as Box<T>` compiled
//             although nothing at run time can tell whether they hold.
// Root cause: TypeAssertion never tested the header type, a flow-narrowed read kept
//             its declared C type, and casts out of unknown had no target rule.
// Fix:        the checker marks an object down-conversion (NodeFlag.ObjCheck), codegen
//             tests it (msObjDownConv / instanceof; null passes), downConvLower gives a
//             narrowed read its class type, and only a non-generic class is a target.

import { hasError, strictErrorCount } from "../handoff/helpers";
import { compileToC, compileToJS } from "../helpers";

function accepts(src: string): boolean {
	return strictErrorCount(src) == 0;
}

const nodes = "class BaseNode { id: int32 = 0; }\nclass NativeNode extends BaseNode { view: string = \"native\"; }\n"
	+ "interface I { v: int32; }\nclass Box<T> { v: T; constructor(v: T) { this.v = v; } }\n";

test "bug601: a class is a checked target" {
	assert accepts(nodes + "function f(u: unknown): string { return (u as NativeNode).view; }");
}

test "bug601: an interface is not a target from unknown" {
	assert hasError(nodes + "function f(u: unknown): int32 { return (u as I).v; }", "only a non-generic class has a runtime identity");
}

test "bug601: a generic class instance is not a target from unknown" {
	assert hasError(nodes + "function f(u: unknown): int32 { return (u as Box<int32>).v; }", "only a non-generic class has a runtime identity");
}

test "bug601: instanceof narrows unknown" {
	assert accepts(nodes + "function f(u: unknown): string { if (u instanceof NativeNode) return u.view; return \"\"; }");
}

test "bug601: a conversion out of unknown and a base-to-derived conversion are tested" {
	const r = compileToC(nodes + "function f(u: unknown): string { return (u as NativeNode).view; }\n"
		+ "function g(b: BaseNode): string { return (b as NativeNode).view; }\nconsole.log(f(new NativeNode()) + g(new NativeNode()));");
	assert r.ok;
	let count = 0;
	let at = r.value.indexOf("msObjDownConv(");
	while (at >= 0) {
		count += 1;
		at = r.value.indexOf("msObjDownConv(", at + 1);
	}
	assert count == 2, "expected two tested conversions, got " + count.toString();
}

test "bug601: an upcast is not tested" {
	const r = compileToC(nodes + "function f(n: NativeNode): BaseNode { return n as BaseNode; }\nconsole.log(f(new NativeNode()).id.toString());");
	assert r.ok;
	assert !r.value.contains("msObjDownConv(");
}

test "bug601: a narrowed read reaches C with its class type" {
	const r = compileToC(nodes + "function f(b: BaseNode): string { if (b instanceof NativeNode) return b.view; return \"\"; }\nconsole.log(f(new NativeNode()));");
	assert r.ok;
	assert r.value.contains("msIsInstance(");
}

test "bug601: JS tests the same conversion with instanceof and the same message" {
	const r = compileToJS(nodes + "function f(u: unknown): string { return (u as NativeNode).view; }\nconsole.log(f(new NativeNode()));");
	assert r.ok;
	assert r.value.contains("instanceof");
	assert r.value.contains("invalid object conversion: ");
}

const aliases = "type Native = NativeNode;\ntype Base = BaseNode;\n";
const throughAliases = "function f(u: unknown): string { return (u as Native).view; }\n"
	+ "function g(n: NativeNode): Base { return n as Base; }\nconsole.log(f(new NativeNode()) + g(new NativeNode()).id.toString());";

test "bug601: an alias of a class is that class as a target, down and up" {
	const r = compileToC(nodes + aliases + throughAliases);
	assert r.ok;
	const first = r.value.indexOf("msObjDownConv(");
	assert first >= 0;
	assert r.value.indexOf("msObjDownConv(", first + 1) < 0, "the upcast through an alias is not tested";
}

test "bug601: JS tests an alias of a class against the class" {
	const r = compileToJS(nodes + aliases + throughAliases);
	assert r.ok;
	assert r.value.contains("instanceof NativeNode");
}
