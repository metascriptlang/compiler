// @stdout: four:42 005 other:007
// @exit: 0
// note: a macro body asks for `tagged<number>` (and, inside it, `padded<number>`) before the program does. The macro checks against the VM's own std, the program against the target's, so each keeps its own instance; C used to call the VM host function `msStringFromValue` and JS a bare `padStart`.

import { Node, NodeKind } from "std/meta";

function padded<T>(x: T): string {
	return String(x).padStart(3, "0");
}

function tagged<T>(x: T): string {
	const s = String(x);
	return s.startsWith("4") ? "four:" + s.toUpperCase() : "other:" + padded<T>(x);
}

macro atCompile(v: Node): Node {
	return { kind: NodeKind.StringLiteral, line: v.line, column: v.column, value: tagged<number>(42) };
}

console.log(`${atCompile(0)} ${padded<number>(5)} ${tagged<number>(7)}`);
