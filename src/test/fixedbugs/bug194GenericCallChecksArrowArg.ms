// bug194 — a mismatched arrow callback was silent in a generic call where the same named function was an error
// Symptom: `xs.map((s: string, flag: boolean): string => …)` and `applyG("a", (s: string, flag: boolean): string => s)`
//          compiled clean while `xs.map(named)` with the same signature reported "Argument type mismatch";
//          the silent program read the int32 index as a boolean and trapped at run time
//          ("load of value 16, which is not valid for type 'MS_BOOL'"). A non-generic formal refused both.
// Root cause: the check of each argument against the formal substituted with the inferred bindings
//             skipped every function literal, so an annotated arrow was never compared with it.
// Fix: that check reads the literal's own checked type like any other argument's; only an argument
//      whose type is unresolved, unknown or already an error is left out. A literal with an
//      unannotated parameter was typed under the first binding, so when a later argument widens
//      the binding it is typed again from the final one before it is compared.

import { compileToCWithStd } from "../helpers";

const PRELUDE = `
import { Node, NodeKind } from "std/meta";
function apply(f: (s: string, i: number) => string): string { return f("a", 1); }
function applyG<T>(x: T, f: (s: T, i: number) => string): string { return f(x, 1); }
function named(s: string, flag: boolean): string { return s; }
class Animal { name: string = "a"; }
class Dog extends Animal { bark: string = "w"; }
function pick<T>(a: T, b: T, f: (v: T) => string): string { return f(b); }
function fits(s: string, i: number): string { return s; }
macro lengthOfMapped(n: Node): Node {
	return { kind: NodeKind.MemberExpr, line: n.line, column: n.column, object: n.callee.object, property: "length", isOptional: false };
}
`;

function errorsOf(body: string): string {
	const r = compileToCWithStd(PRELUDE + "function main(): void { const xs: string[] = [\"a\", \"b\"]; " + body + " }");
	if (r.ok) return "";
	return r.error;
}

test "bug194: a mismatched arrow is refused by a generic function like the named function" {
	const arrow = errorsOf("console.log(applyG(\"a\", (s: string, flag: boolean): string => s));");
	const viaNamed = errorsOf("console.log(applyG(\"a\", named));");
	assert arrow.contains("Argument type mismatch in 'applyG' arg 1"), arrow;
	assert viaNamed.contains("Argument type mismatch in 'applyG' arg 1"), viaNamed;
}

test "bug194: a mismatched arrow is refused by a generic method like the named function" {
	const arrow = errorsOf("console.log(xs.map((s: string, flag: boolean): string => s).length);");
	const viaNamed = errorsOf("console.log(xs.map(named).length);");
	assert arrow.contains("Argument type mismatch in 'map' arg 0"), arrow;
	assert viaNamed.contains("Argument type mismatch in 'map' arg 0"), viaNamed;
}

test "bug194: a non-generic formal keeps refusing both" {
	assert errorsOf("console.log(apply((s: string, flag: boolean): string => s));").contains("Argument type mismatch in 'apply' arg 0");
	assert errorsOf("console.log(apply(named));").contains("Argument type mismatch in 'apply' arg 0");
}

test "bug194: inside a macro argument the rule is the same for the arrow and the named function" {
	const arrow = errorsOf("console.log(lengthOfMapped(xs.map((s: string, flag: boolean): string => s)));");
	const viaNamed = errorsOf("console.log(lengthOfMapped(xs.map(named)));");
	assert arrow.contains("Argument type mismatch in 'map' arg 0"), arrow;
	assert viaNamed.contains("Argument type mismatch in 'map' arg 0"), viaNamed;
}

test "bug194: a callback that fits compiles, annotated, untyped, shorter or named" {
	assert errorsOf("console.log(xs.map((s: string, i: number): string => s).length);") == "";
	assert errorsOf("console.log(xs.map(s => s + \"!\").length);") == "";
	assert errorsOf("console.log(xs.map((s: string): string => s).length);") == "";
	assert errorsOf("console.log(xs.map(fits).length);") == "";
	assert errorsOf("console.log(applyG(\"a\", (s: string, i: number): string => s));") == "";
	assert errorsOf("console.log(applyG(\"a\", s => s));") == "";
	assert errorsOf("console.log(lengthOfMapped(xs.map(s => s)));") == "";
}

test "bug194: a mismatched return type is refused in a generic call" {
	const e = errorsOf("console.log(applyG(\"a\", (s: string, i: number): boolean => true));");
	assert e.contains("Argument type mismatch in 'applyG' arg 1"), e;
}

test "bug194: an unannotated arrow is typed from the widened binding, not the first one" {
	assert errorsOf("console.log(pick(new Dog(), new Animal(), a => a.name));") == "";
	assert errorsOf("console.log(pick(new Dog(), new Animal(), (a: Animal): string => a.name));") == "";
	const reads = errorsOf("console.log(pick(new Dog(), new Animal(), a => a.bark));");
	assert reads.contains("'bark'"), reads;
	const annotated = errorsOf("console.log(pick(new Dog(), new Animal(), (a: Dog): string => a.bark));");
	assert annotated.contains("Argument type mismatch in 'pick' arg 2"), annotated;
}
