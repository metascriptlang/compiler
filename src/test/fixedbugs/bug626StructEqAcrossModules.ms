// Symptom: `==` on a struct whose field type is declared in a module the comparing module does not import called an Eq nothing defined (C `call to undeclared function 'InnerEq'`, JS `InnerEq is not defined`); a struct named like one in another module took that module's Eq (C type mismatch, JS compared the wrong fields and answered equal).
// Root cause: the lifter found a field's Eq by the field type's name in the comparing module's scope and keyed it by that bare name; Nim instantiates `==`[T: tuple|object] (system.nim:2058) once per type, whatever names the caller sees (seminst.nim generateInstance, genericCacheGet).
// Fix: each struct Eq is built from the Type it compares and named after the type's C name, the key the lifecycle hooks already use.
// C runs in corpus 663: compileProjectToC takes its alive set before the transform, so no generated Eq body reaches its output.
import { compileProjectToJS } from "../helpers";
import { MapEntry } from "../../module/loader";

const INNER = "export struct Inner { a: uint8; b: uint8; }\n";
const OUTER = "import { Inner } from \"./inner\";\n"
	+ "export struct Outer { id: int32; inner: Inner; }\n";
const DEEP = "export struct Deep { k: uint16; }\n";
const MID = "import { Deep } from \"./deep\";\nexport struct Mid { a: uint8; d: Deep; }\n";
const TOP = "import { Mid } from \"./mid\";\nexport struct Top { id: int32; m: Mid; }\n";
const MAIN = `
import { Outer } from "./outer";
import { Top } from "./top";
struct Inner { tag: string; }
function sameOuter(x: Outer, y: Outer): boolean { return x == y; }
function sameTop(x: Top, y: Top): boolean { return x == y; }
function sameLocal(p: Inner, q: Inner): boolean { return p == q; }
const o: Outer = { id: 1, inner: { a: 0, b: 1 } };
const t: Top = { id: 1, m: { a: 2, d: { k: 3 } } };
const l: Inner = { tag: "t" };
console.log(sameOuter(o, o), sameTop(t, t), sameLocal(l, l));
`;

function project(): string {
	const entries: MapEntry[] = [
		{ entryPath: "test/bug626/inner.ms", entrySource: INNER },
		{ entryPath: "test/bug626/outer.ms", entrySource: OUTER },
		{ entryPath: "test/bug626/deep.ms", entrySource: DEEP },
		{ entryPath: "test/bug626/mid.ms", entrySource: MID },
		{ entryPath: "test/bug626/top.ms", entrySource: TOP },
		{ entryPath: "test/bug626/main.ms", entrySource: MAIN },
	];
	return compileProjectToJS(entries, "test/bug626/main.ms");
}

function isIdentChar(c: string): boolean {
	return (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9")
		|| c == "_" || c == "$";
}

function calleeOf(out: string, args: string): string {
	const at = out.indexOf(args, 0);
	if (at < 0) return "";
	let start = at;
	while (start > 0) {
		if (!isIdentChar(out.charAt(start - 1))) break;
		start -= 1;
	}
	return out.slice(start, at);
}

function defines(out: string, name: string): boolean {
	const head = "function " + name + "(";
	let at = out.indexOf(head, 0);
	while (at >= 0) {
		const end = out.indexOf("\n", at);
		const line = out.slice(at, end < 0 ? out.length : end).trimEnd();
		if (line.endsWith("{")) return true;
		at = out.indexOf(head, at + 1);
	}
	return false;
}

function nestedEqsUndefined(): string {
	const out = project();
	if (out.startsWith("ERROR")) return out;
	for (const field of ["inner", "m", "d"]) {
		const callee = calleeOf(out, `(a.${field}, b.${field})`);
		if (!callee.endsWith("Eq") || !defines(out, callee)) return `${field}: '${callee}'`;
	}
	return "";
}

function localNameEqClash(): string {
	const out = project();
	if (out.startsWith("ERROR")) return out;
	const nested = calleeOf(out, "(a.inner, b.inner)");
	const local = calleeOf(out, "(p, q);");
	if (!nested.endsWith("Eq") || !local.endsWith("Eq")) return `'${nested}' / '${local}'`;
	if (nested == local) return `both call '${nested}'`;
	if (!defines(out, nested) || !defines(out, local)) return `'${nested}' / '${local}' undefined`;
	return "";
}

test "bug626: a nested field's Eq is defined when its type's module is not imported" {
	const failure = nestedEqsUndefined();
	assert failure == "", failure;
}

test "bug626: a local struct named like a nested foreign one keeps its own Eq" {
	const failure = localNameEqClash();
	assert failure == "", failure;
}
