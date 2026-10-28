// @stdout: first=b past=[] multi=[é] loop=cba digits=2F param=c tmpl=[x] cmp=1
// note: indexing a string in a function a macro calls reads one character like the compiled program: past the end is the empty string, a character is one code point, an index can be a parameter or a loop variable, a module-level const string is indexable, and the result compares with ==.

import { Node, NodeKind } from "std/meta";

const DIGITS = "0123456789ABCDEF";

function at(s: string, i: int32): string { return s[i]; }
function reversed(s: string): string {
	let out = "";
	for (let i = s.length - 1; i >= 0; i--) { out += s[i]; }
	return out;
}
function digit(n: int32): string { return DIGITS[n]; }
function isLowerC(s: string): int32 { return s[2] == "c" ? 1 : 0; }

macro table(): Node {
	const s = "first=" + at("abc", 1) + " past=[" + at("abc", 9) + "] multi=[" + at("héy", 1) + "]"
		+ " loop=" + reversed("abc") + " digits=" + digit(2) + digit(15)
		+ " param=" + at("abc", 2) + " tmpl=[" + `${at("xyz", 0)}` + "] cmp=" + String(isLowerC("abc"));
	return { kind: NodeKind.StringLiteral, line: 1, column: 1, value: s };
}

console.log(table());
