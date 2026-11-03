import { compileToC, compileToJSWithStd } from "../helpers";
import { checkSource } from "./helpers";
import { Severity } from "../../checker/context";

const DECLS = `struct P { x: int32; y: int32; }
class R { readonly ro: int32 = 1; w: int32 = 0; }
class G { v: int32 = 0; get g(): int32 { return this.v; } }
class H { readonly items: int32[] = []; }
function mk(): P { return { x: 1, y: 2 }; }
let n: int32 = 0;
let m: int32 = 0;
`;

function errorsOf(body: string): string {
	const ctx = checkSource(DECLS + body);
	if (ctx == null) return "parse failed";
	const messages: string[] = [];
	for (const err of ctx.errors) if (err.severity == Severity.Error) messages.push(err.message);
	return messages.join(" | ");
}

function refusedAsDirect(name: string, direct: string, pattern: string): string {
	const expected = errorsOf(direct);
	if (expected == "") return name + ": the direct write was accepted";
	const got = errorsOf(pattern);
	return got == expected ? "" : `${name}: pattern gave '${got}', direct gave '${expected}'`;
}

test "destructuringWriteTargets: an array pattern leaf is refused with the message of the same direct write" {
	const cases = [
		{ name: "value-type parameter field", direct: "function f(p: P): void { p.x = 7; }", pattern: "function f(p: P): void { [p.x, n] = [7, 8]; }" },
		{ name: "readonly property", direct: "const r = new R(); r.ro = 5;", pattern: "const r = new R(); [r.ro, n] = [5, 6];" },
		{ name: "const struct field", direct: "const a: P = { x: 1, y: 2 }; a.x = 5;", pattern: "const a: P = { x: 1, y: 2 }; [a.x, n] = [5, 6];" },
		{ name: "const binding", direct: "const c: int32 = 1; c = 2;", pattern: "const c: int32 = 1; [c, n] = [2, 3];" },
		{ name: "string length", direct: "let s = \"abc\"; s.length = 1;", pattern: "let s = \"abc\"; [s.length, n] = [1, 2];" },
		{ name: "fixed-size array length", direct: "let a: int32[3] = [1, 2, 3]; a.length = 1;", pattern: "let a: int32[3] = [1, 2, 3]; [a.length, n] = [1, 2];" },
		{ name: "getter without setter", direct: "const r = new G(); r.g = 5;", pattern: "const r = new G(); [r.g, n] = [5, 6];" },
		{ name: "field of a call result", direct: "mk().x = 5;", pattern: "[mk().x, n] = [5, 6];" },
	];
	for (const c of cases) {
		const verdict = refusedAsDirect(c.name, c.direct, c.pattern);
		assert verdict == "", verdict;
	}
}

test "destructuringWriteTargets: a nested array pattern leaf is refused like a direct write" {
	const verdict = refusedAsDirect("nested", "const r = new R(); r.ro = 5;", "const r = new R(); [n, [r.ro, m]] = [1, [5, 6]];");
	assert verdict == "", verdict;
}

test "destructuringWriteTargets: a rest target is refused like a direct write" {
	const verdict = refusedAsDirect("rest", "const h = new H(); h.items = [2, 3];", "const h = new H(); [n, ...h.items] = [1, 2, 3];");
	assert verdict == "", verdict;
}

test "destructuringWriteTargets: an object pattern leaf is refused like a direct write" {
	const verdict = refusedAsDirect("object", "const r = new R(); r.ro = 5;", "const r = new R(); ({ a: r.ro, b: n } = { a: 5, b: 6 });");
	assert verdict == "", verdict;
}

test "destructuringWriteTargets: a growable array length stays a destructuring target on C and JS" {
	const source = "let a = [1, 2, 3];\nlet k = 0;\n[a.length, k] = [1, 2];\nconsole.log(a.length.toString() + \" \" + k.toString());";
	const c = compileToC(source);
	assert c.ok, c.ok ? "" : c.error;
	const js = compileToJSWithStd(source);
	assert js.ok, js.ok ? "" : js.error;
}
