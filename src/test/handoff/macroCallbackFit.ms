import { compileToCWithStd } from "../helpers";

const callbackSource = `
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

test "macro callback fit: annotation and syntax never bypass the instantiated formal" {
	const cases = [
		{ body: "console.log(applyG(\"a\", (s: string, flag: boolean): string => s));", accepted: false },
		{ body: "console.log(applyG(\"a\", named));", accepted: false },
		{ body: "console.log(xs.map((s: string, flag: boolean): string => s).length);", accepted: false },
		{ body: "console.log(xs.map(named).length);", accepted: false },
		{ body: "console.log(apply((s: string, flag: boolean): string => s));", accepted: false },
		{ body: "console.log(apply(named));", accepted: false },
		{ body: "console.log(lengthOfMapped(xs.map((s: string, flag: boolean): string => s)));", accepted: false },
		{ body: "console.log(lengthOfMapped(xs.map(named)));", accepted: false },
		{ body: "console.log(xs.map((s: string, i: number): string => s).length);", accepted: true },
		{ body: "console.log(xs.map(s => s + \"!\").length);", accepted: true },
		{ body: "console.log(xs.map((s: string): string => s).length);", accepted: true },
		{ body: "console.log(xs.map(fits).length);", accepted: true },
		{ body: "console.log(applyG(\"a\", (s: string, i: number): string => s));", accepted: true },
		{ body: "console.log(applyG(\"a\", s => s));", accepted: true },
		{ body: "console.log(lengthOfMapped(xs.map(s => s)));", accepted: true },
		{ body: "console.log(applyG(\"a\", (s: string, i: number): boolean => true));", accepted: false },
		{ body: "console.log(pick(new Dog(), new Animal(), a => a.name));", accepted: true },
		{ body: "console.log(pick(new Dog(), new Animal(), (a: Animal): string => a.name));", accepted: true },
		{ body: "console.log(pick(new Dog(), new Animal(), a => a.bark));", accepted: false },
		{ body: "console.log(pick(new Dog(), new Animal(), (a: Dog): string => a.bark));", accepted: false },
	];
	for (const item of cases) {
		const source = callbackSource + 'function main(): void { const xs: string[] = ["a", "b"]; ' + item.body + " }";
		assert compileToCWithStd(source).ok == item.accepted, item.body;
	}
}
