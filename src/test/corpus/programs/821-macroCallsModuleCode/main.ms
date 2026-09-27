// @stdout: 11 002 33 [4]
// @exit: 0
// note: a macro calls code of the modules it can see: a function and a generic of another module that use that module's own extension, a generic of another module that uses a std method, and an extension of its own module. The macro VM checks each body against its own std with the extensions of the body's module; it used to miss those extensions, and checked the other module's generic in the build's std, where the std method matched twice.

import { Node, NodeKind } from "std/meta";
import { doubled, padded, doubledOf } from "./lib";

function bracketed(this s: string): string {
	return "[" + s + "]";
}

macro atCompile(v: Node): Node {
	const s = doubled(1) + " " + padded<number>(2) + " " + doubledOf<number>(3) + " " + "4".bracketed();
	return { kind: NodeKind.StringLiteral, line: v.line, column: v.column, value: s };
}

console.log(atCompile(0));
console.log(doubled(1) + " " + padded<number>(2) + " " + doubledOf<number>(3) + " " + "4".bracketed());
