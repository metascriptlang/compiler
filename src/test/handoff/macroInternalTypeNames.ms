import { compileToCWithStd, compileToJSWithStd } from "../helpers";

function buildFailure(source: string, label: string): string {
	const c = compileToCWithStd(source);
	if (!c.ok) return label + " (C): " + c.error;
	const js = compileToJSWithStd(source);
	if (!js.ok) return label + " (JS): " + js.error;
	return "";
}

function failures(cases: string[]): string {
	return cases.filter((r: string): boolean => r != "").join("\n");
}

test "macroInternalTypeNames: a module declaring its own Node, NodeKind or DeclKind does not capture the macro program" {
	const bad = failures([
		buildFailure(`
import { Node as MNode, NodeKind as MK } from "std/meta";
class Node { n: int32 = 1; }
enum NodeKind { Alpha, Beta }
export macro m(x: MNode): MNode { return { kind: MK.NumberLiteral, line: x.line, column: x.column, value: 1 }; }
const v: int32 = m(0);
console.log(v, new Node().n, NodeKind.Beta);
`, "aliased std names"),
		buildFailure(`
import { Node } from "std/meta";
enum NodeKind { Alpha, Beta }
export macro m(x: Node): Node { return quote { 1 }; }
const v: int32 = m(0);
console.log(v, NodeKind.Beta);
`, "own NodeKind beside a quote"),
		buildFailure(`
import { Node } from "std/meta";
enum DeclKind { Fixed, Loose }
export macro m(x: Node): Node { return quote { (() => { const a: int32 = 2; return a; })() }; }
const v: int32 = m(0);
console.log(v, DeclKind.Loose);
`, "own DeclKind beside a quoted declaration"),
	]);
	assert bad == "", bad;
}

test "macroInternalTypeNames: a macro module that never imports Node still compiles its body" {
	const bad = failures([
		buildFailure(`
import { warning } from "std/meta";
class Node { n: int32 = 1; }
export macro m(x) { return quote { 1 }; }
const v: int32 = m(0);
console.log(v, new Node().n);
`, "own Node, no std Node"),
		buildFailure(`
import { warning } from "std/meta";
export macro m(x) { return quote { 1 }; }
const v: int32 = m(0);
console.log(v);
`, "no Node anywhere"),
	]);
	assert bad == "", bad;
}

test "macroInternalTypeNames: a decorator macro keeps its wrapper beside a module Node and NodeKind" {
	const bad = failures([
		buildFailure(`
import { Node as MNode, ClassFieldDecoratorContext } from "std/meta";
class Node { n: int32 = 1; }
enum NodeKind { Alpha, Beta }
macro keepField(value: MNode, context: ClassFieldDecoratorContext): MNode { return value; }
class G { @keepField base: int32 = 7; }
console.log(new G().base, new Node().n, NodeKind.Beta);
`, "field decorator"),
		buildFailure(`
import { Node as MNode, NodeKind as MK, ClassFieldDecoratorContext } from "std/meta";
class Node { n: int32 = 1; }
macro scale(k: int32): (value: MNode, context: ClassFieldDecoratorContext) => (init: MNode) => MNode {
	return (value: MNode, context: ClassFieldDecoratorContext): (init: MNode) => MNode => {
		return (init: MNode): MNode => ({ kind: MK.NumberLiteral, line: init.line, column: init.column, value: k, isFloat: false });
	};
}
class G { @scale(3) tripled: int32 = 5; }
console.log(new G().tripled, new Node().n);
`, "factory decorator"),
	]);
	assert bad == "", bad;
}

test "macroInternalTypeNames: bindSym and getTypeImpl results are the std Node beside a module Node" {
	const bad = failures([
		buildFailure(`
import { Node as MNode, NodeKind as MK, bindSym } from "std/meta";
class Node { n: int32 = 1; }
enum NodeKind { Alpha, Beta }
export function pick(): int32 { return 4; }
export macro first(x: MNode): MNode {
	const bound = bindSym("pick");
	return { kind: MK.CallExpr, line: x.line, column: x.column, callee: bound, arguments: [], isDirectCall: false, resolvedOverloadIdx: -1 };
}
const v: int32 = first(0);
console.log(v, new Node().n, NodeKind.Beta);
`, "bindSym"),
		buildFailure(`
import { Node as MNode, NodeKind as MK, getTypeImpl, bindSym } from "std/meta";
class Node { n: int32 = 1; }
enum NodeKind { Alpha, Beta }
struct Pt { x: int32; y: int32; }
export macro count(x: MNode): MNode {
	const impl = getTypeImpl(bindSym("Pt"));
	return { kind: MK.NumberLiteral, line: x.line, column: x.column, value: 2, isFloat: false };
}
const v: int32 = count(0);
console.log(v, new Node().n);
`, "getTypeImpl"),
	]);
	assert bad == "", bad;
}

test "macroInternalTypeNames: warning() logs through the std console beside a module const of that name" {
	const bad = failures([
		buildFailure(`
import { Node, NodeKind, warning } from "std/meta";
const console: int32 = 3;
export macro m(x: Node): Node {
	warning("careful");
	return { kind: NodeKind.NumberLiteral, line: x.line, column: x.column, value: 1 };
}
const v: int32 = m(0);
`, "module const console"),
		buildFailure(`
import { Node, NodeKind, warning } from "std/meta";
class console { static other: int32 = 1; }
export macro m(x: Node): Node {
	warning("careful", x);
	return { kind: NodeKind.NumberLiteral, line: x.line, column: x.column, value: 1 };
}
const v: int32 = m(0);
`, "module class console"),
	]);
	assert bad == "", bad;
}
