import { checkSource, strictErrorCount, warningCount } from "./helpers";
import { compileToC, compileToCWithStd } from "../helpers";
import { parseSource } from "../../parser/statements/validation";
import { resetAllSideChannels } from "../../parser/context";
import { checkProgramWithRegistry } from "../../checker/checkPass";
import { getPreludeContext } from "../../checker/orchestrator";
import { ExportRegistry, Severity } from "../../checker/context";
import { Module, ModuleGraph } from "../../module/graph";
import { NodeKind, ProgramData, FunctionDeclData, BlockStmtData, ExprStmtData, MatchExprData, createNodeAt } from "../../ast/node";

test "declarationBoundaries: inheritance follows acyclic paths, not a depth limit" {
	const cases0 = [
		{ name: "mutual cycle (A extends B, B extends A) errors gracefully", source: "\nclass A extends B { x: int32; }\nclass B extends A { y: int32; }\n", expected: -1 },
		{ name: "3-level cycle (A→C, B→A, C→B) errors gracefully", source: "\nclass A extends C { x: int32; }\nclass B extends A { y: int32; }\nclass C extends B { z: int32; }\n", expected: -1 },
		{ name: "direct self-cycle still detected", source: "class A extends A { x: int32; }", expected: -1 },
		{ name: "linear inheritance (no cycle) still compiles", source: "\nclass A1 { x: int32; constructor(x: int32) { this.x = x; } }\nclass B1 extends A1 { y: int32; constructor(x: int32, y: int32) { super(x); this.y = y; } }\nclass C1 extends B1 { z: int32; constructor(x: int32, y: int32, z: int32) { super(x, y); this.z = z; } }\n\nfunction main(): void {\n\tconst c = new C1(1, 2, 3);\n\tconst _x = c.x;\n}\n", expected: 0 },
	];
	for (const item of cases0) {
		const result = compileToC(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
	const cases1 = [
		{ name: "two-interface extends cycle is an error", source: "interface A extends B { a: number; }\ninterface B extends A { b: number; }", expected: -1 },
		{ name: "three-interface extends cycle is an error", source: "interface A extends B { a: number; }\ninterface B extends C { b: number; }\ninterface C extends A { c: number; }", expected: -1 },
		{ name: "direct self-cycle still errors", source: "interface A extends A { a: number; }", expected: -1 },
		{ name: "a straight extends chain stays legal", source: "interface C { c: number; }\ninterface B extends C { b: number; }\ninterface A extends B { a: number; }\nconst x: A = { a: 1, b: 2, c: 3 };", expected: 0 },
		{ name: "a diamond is not a false cycle", source: "interface D { }\ninterface B extends D { b: number; }\ninterface C extends D { c: number; }\ninterface A extends B, C { a: number; }", expected: 0 },
		{ name: "a generic parent chain stays legal", source: "interface Box<T> { item: T; }\ninterface Tagged extends Box<number> { tag: string; }", expected: 0 },
	];
	for (const item of cases1) {
		const errors = strictErrorCount(item.source);
		assert item.expected < 0 ? errors > 0 : errors == item.expected, item.name;
	}
}

test "declarationBoundaries: annotation boundaries distinguish unknown from unsupported any" {
	const cases = [
		{ name: "annotation 'any' is rejected with guidance", source: "function f(x: any): void {}", expected: -1 },
		{ name: "compound 'any' positions are rejected too", source: "function f(): any[] { return []; }", expected: -1 },
		{ name: "'unknown' stays legal", source: "function f(x: unknown): void {}", expected: 0 },
		{ name: "the null cast idiom stays legal", source: "interface T { v: int32; } function f(): T { return null as unknown as T; }", expected: 0 },
	];
	for (const item of cases) {
		const errors = strictErrorCount(item.source);
		assert item.expected < 0 ? errors > 0 : errors == item.expected, item.name;
	}
}

test "declarationBoundaries: assignment produces a statement, not a value" {
	const cases = [
		{ name: "assignment as a return value is rejected", source: "function f(x: string): string { let l = x; return l = x; }", expected: -1 },
		{ name: "chained assignment is rejected", source: "function f(): void { let a = \"\"; let b = \"\"; a = b = \"x\"; }", expected: -1 },
		{ name: "assignment inside a condition is rejected", source: "function f(): void { let l = \"\"; while ((l = \"a\") !== \"\") { } }", expected: -1 },
		{ name: "member access on an assignment result is rejected", source: "function f(): string { let n = 0; return (n = 5).toString(); }", expected: -1 },
		{ name: "an assignment initializer is rejected", source: "function f(): void { let s = \"\"; const r: int32 = (s = \"x\"); }", expected: -1 },
		{ name: "statement-position assignment stays legal", source: "class B { v: string = \"\"; } function f(): void { let x = \"a\"; x = \"b\"; x += \"c\"; const arr: string[] = [\"p\"]; arr[0] = \"z\"; const b = new B(); b.v = \"w\"; }", expected: 0 },
		{ name: "for-update assignment stays legal", source: "function f(): int32 { let n = 0; for (let i = 0; i < 3; i = i + 1) { n = n + i; } for (let j = 0; j < 3; j += 1) { n = n + j; } return n; }", expected: 0 },
	];
	for (const item of cases) {
		const errors = strictErrorCount(item.source);
		assert item.expected < 0 ? errors > 0 : errors == item.expected, item.name;
	}
}

test "declarationBoundaries: destructuring assignments fit writable targets" {
	const cases = [
		{ name: "a pattern of mixed targets takes a tuple", source: "\nlet a: int32 = 1;\nlet b: int32 = 2;\nlet w: string = \"x\";\nlet r: int32[] = [];\nconst src: int32[] = [3, 4, 5];\n[a, w] = [2, \"y\"];\n", expected: 0 },
		{ name: "a nested pattern and a rest target are accepted", source: "\nlet a: int32 = 1;\nlet b: int32 = 2;\nlet w: string = \"x\";\nlet r: int32[] = [];\nconst src: int32[] = [3, 4, 5];\n[a, [b]] = [1, [2]];\n[a, ...r] = src;\n", expected: 0 },
		{ name: "a literal is not an assignment target", source: "\nlet a: int32 = 1;\nlet b: int32 = 2;\nlet w: string = \"x\";\nlet r: int32[] = [];\nconst src: int32[] = [3, 4, 5];\n[1, b] = src;\n", expected: -1 },
		{ name: "a rest target needs the other targets' element type", source: "\nlet a: int32 = 1;\nlet b: int32 = 2;\nlet w: string = \"x\";\nlet r: int32[] = [];\nconst src: int32[] = [3, 4, 5];\n[w, ...r] = [\"s\", 1];\n", expected: -1 },
		{ name: "a pattern takes only a plain assignment", source: "\nlet a: int32 = 1;\nlet b: int32 = 2;\nlet w: string = \"x\";\nlet r: int32[] = [];\nconst src: int32[] = [3, 4, 5];\n[a, b] += src;\n", expected: -1 },
	];
	for (const item of cases) {
		const result = compileToC(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "declarationBoundaries: lifecycle hooks require a writable receiver representation" {
	const cases = [
		{ name: "onCopy on a value struct receiver is refused at the declaration", source: "struct Res { h: int32; }\nfunction onCopy(this self: Res, src: Res): void { console.log(src.h.toString()); }\n", expected: -1 },
		{ name: "onMoved on a value struct receiver is refused at the declaration", source: "struct Res { h: int32; }\nfunction onMoved(this self: Res): void { console.log(self.h.toString()); }\n", expected: -1 },
		{ name: "a class receiver is a reference and keeps its onCopy", source: "class Obj { h: int32 = 0; }\nfunction onCopy(this self: Obj, src: Obj): void { self.h = src.h; }\n", expected: 0 },
	];
	for (const item of cases) {
		const errors = strictErrorCount(item.source);
		assert item.expected < 0 ? errors > 0 : errors == item.expected, item.name;
	}
}

test "declarationBoundaries: nonvoid functions close every reachable exit" {
	const cases = [
		{ name: "a named function that falls off on one path is refused", source: "function num(flag: boolean): int32 {\n\tif (flag) { return 5; }\n}\n", expected: -1 },
		{ name: "a named function that falls off on one path is refused", source: "class Foo { x: int32 = 7; }\nfunction pick(flag: boolean): Foo {\n\tif (flag) { return new Foo(); }\n}\n", expected: -1 },
		{ name: "a named function that falls off on one path is refused", source: "function maybe(flag: boolean): string | null {\n\tif (flag) return \"a\";\n}\n", expected: -1 },
		{ name: "a method, an async function, a switch and a loop that fall off are refused", source: "class W { run(flag: boolean): string { if (flag) { return \"a\"; } } }\n", expected: -1 },
		{ name: "a method, an async function, a switch and a loop that fall off are refused", source: "async function ag(flag: boolean): Promise<int32> { if (flag) { return 1; } }\n", expected: -1 },
		{ name: "a method, an async function, a switch and a loop that fall off are refused", source: "function sw(k: int32): string { switch (k) { case 1: return \"a\"; } }\n", expected: -1 },
		{ name: "a method, an async function, a switch and a loop that fall off are refused", source: "function lp(n: int32): int32 { for (let i = 0; i < n; i++) { if (i == 3) return i; } }\n", expected: -1 },
		{ name: "an arrow that falls off is refused whether its return type is written, contextual or inferred", source: "const a = (flag: boolean): int32 => { if (flag) { return 1; } };\n", expected: -1 },
		{ name: "an arrow that falls off is refused whether its return type is written, contextual or inferred", source: "function takeCb(cb: (n: int32) => boolean): boolean { return cb(1); }\nconst r = takeCb((n) => { if (n > 0) { return true; } });\n", expected: -1 },
		{ name: "an arrow that falls off is refused whether its return type is written, contextual or inferred", source: "const inferred = (flag: boolean) => { if (flag) { return 1; } };\n", expected: -1 },
		{ name: "a never function whose end is reachable is refused", source: "function nv(flag: boolean): never { if (flag) { throw new Error(\"x\"); } }\n", expected: -1 },
		{ name: "a body whose every path returns, throws or never returns stays accepted", source: "function fail(msg: string): never { throw new Error(msg); }\nfunction a(flag: boolean): int32 { if (flag) { return 1; } else { return 2; } }\nfunction b(flag: boolean): int32 { while (true) { if (flag) return 1; } }\nfunction c(flag: boolean): int32 { if (flag) return 1; throw new Error(\"x\"); }\nfunction d(flag: boolean): int32 { if (flag) return 1; fail(\"no\"); }\nfunction e(k: int32): string { switch (k) { case 1: return \"a\"; default: return \"b\"; } }\nfunction m(k: int32): int32 { match (k) { 1 => { return 1; }, _ => { return 2; } } }\nfunction f(flag: boolean): void { if (flag) { return; } }\nfunction h(flag: boolean): int32 | void { if (flag) return 1; }\nasync function g(flag: boolean): Promise<void> { if (flag) return; }\nfunction nv(): never { while (true) { } }\nconst ok = (flag: boolean) => { if (flag) { return 1; } return 2; };\n", expected: 0 },
	];
	for (const item of cases) {
		const errors = strictErrorCount(item.source);
		assert item.expected < 0 ? errors > 0 : errors == item.expected, item.name;
	}
}

test "declarationBoundaries: iteration accepts values rather than unsupported property enumeration" {
	const cases = [
		{ name: "a for...in over an object literal is refused", source: "function f(): int32 {\n\tconst obj = { x: 1, y: 2 };\n\tlet n: int32 = 0;\n\tfor (const k in obj) { n = n + 1; }\n\treturn n;\n}\n", expected: -1 },
		{ name: "a for...in with a let binding over an array is refused too", source: "function g(xs: int32[]): int32 {\n\tlet n: int32 = 0;\n\tfor (let i in xs) { n = n + 1; }\n\treturn n;\n}\n", expected: -1 },
		{ name: "a for...of over the same array stays accepted", source: "function h(xs: int32[]): int32 {\n\tlet n: int32 = 0;\n\tfor (const x of xs) { n = n + x; }\n\treturn n;\n}\n", expected: 0 },
	];
	for (const item of cases) {
		const errors = strictErrorCount(item.source);
		assert item.expected < 0 ? errors > 0 : errors == item.expected, item.name;
	}
}

test "declarationBoundaries: switch cases cannot complete into a following case" {
	const cases = [
		{ name: "an integer case that completes into the next case is refused", source: "function ints(n: int32): string {\n\tlet r = \"\";\n\tswitch (n) {\n\t\tcase 1:\n\t\t\tr = r + \"one;\";\n\t\tcase 2:\n\t\t\tr = r + \"two;\";\n\t\t\tbreak;\n\t\tdefault:\n\t\t\tr = r + \"d;\";\n\t}\n\treturn r;\n}\n", expected: -1 },
		{ name: "a string case whose if has one open branch is refused", source: "function strs(s: string, f: boolean): int32 {\n\tlet r: int32 = 0;\n\tswitch (s) {\n\t\tcase \"a\":\n\t\t\tif (f) { break; }\n\t\t\tr = 1;\n\t\tcase \"b\":\n\t\t\tr = 2;\n\t\t\tbreak;\n\t}\n\treturn r;\n}\n", expected: -1 },
		{ name: "stacked labels, closed cases and an open last case stay accepted", source: "function ok(n: int32, f: boolean): int32 {\n\tlet r: int32 = 0;\n\tswitch (n) {\n\t\tcase 1:\n\t\tcase 2:\n\t\t\tr = 2;\n\t\t\tbreak;\n\t\tcase 3:\n\t\t\tif (f) { return 1; } else { return 2; }\n\t\tcase 4:\n\t\t\tthrow new Error(\"four\");\n\t\tdefault:\n\t\t\tr = 9;\n\t}\n\treturn r;\n}\n", expected: 0 },
	];
	for (const item of cases) {
		const errors = strictErrorCount(item.source);
		assert item.expected < 0 ? errors > 0 : errors == item.expected, item.name;
	}
}

test "declarationBoundaries: unsupported value generics stop at their declaration" {
	const cases = [
		{ name: "a const parameter of a generic class is refused by name", source: "class Matrix<const ROWS: int32> { rows(): int32 { return ROWS; } }\nconst m = new Matrix<2>();", expected: -1 },
		{ name: "a const parameter of a generic function is refused by name", source: "function fill<T, const N: int32>(x: T): T[] { return [x]; }", expected: -1 },
		{ name: "the Matrix of two const parameters stops at one diagnostic", source: "\nclass Matrix<const ROWS: int32, const COLS: int32> {\n\tgetTotalElements(): int32 { return ROWS * COLS; }\n}\nconst a = new Matrix<2, 3>();\nconsole.log(a.getTotalElements());\n", expected: -1 },
		{ name: "a type parameter spelled Const is still a type parameter", source: "function first<T, Const>(x: T, y: Const): T { return x; }\nconsole.log(first(1 as int32, \"s\"));", expected: 0 },
	];
	for (const item of cases) {
		const result = compileToC(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "declaration boundaries: null aliases warn once without changing the accepted type" {
	assert warningCount("let x: undefined = null;") - warningCount("let x: null = null;") == 1;
	assert strictErrorCount("let x: undefined = null;") == 0;
	assert strictErrorCount("function f(s: string | undefined): boolean { return s === null; }") == 0;
}

function builtMatchErrors(source: string): int32 {
	checkSource("const warm: int32 = 0;");
	resetAllSideChannels();
	const parsed = parseSource(source);
	if (!parsed.ok) return -1;
	const fn = (parsed.value.data as ProgramData).programStmts[0];
	const body = (fn.data as FunctionDeclData).fnBody.data as BlockStmtData;
	for (let i = 0; i < body.statements.length; i += 1) {
		const statement = body.statements[i];
		if (statement.kind != NodeKind.ExprStmt || (statement.data as ExprStmtData).expr.kind != NodeKind.MatchExpr) continue;
		const matchData = (statement.data as ExprStmtData).expr.data as MatchExprData;
		body.statements[i] = createNodeAt(NodeKind.MatchStmt, { matchStmtDisc: matchData.matchDisc, matchStmtCases: matchData.matchCases }, statement.location);
	}
	const ctx = checkProgramWithRegistry(parsed.value, null as unknown as ExportRegistry, null as unknown as ModuleGraph, null as unknown as Module, getPreludeContext());
	let errors: int32 = 0;
	for (const error of ctx.errors) if (error.severity == Severity.Error) errors += 1;
	return errors;
}

test "declaration boundaries: match coverage depends on selector domain and source form" {
	const cases = [
		{ selector: "boolean", arms: "true => 1,", accepted: false },
		{ selector: "boolean", arms: "true => 1, false => 2,", accepted: true },
		{ selector: "int32", arms: "1 => 1, 2 => 2,", accepted: false },
		{ selector: "int32", arms: "1 => 1, _ => 2,", accepted: true },
		{ selector: "\"row\" | \"column\"", arms: "\"row\" => 1,", accepted: false },
		{ selector: "\"row\" | \"column\"", arms: "\"row\" => 1, \"column\" => 2,", accepted: true },
	];
	for (const item of cases) {
		const source = "function f(value: " + item.selector + "): int32 { return match (value) { " + item.arms + " }; }";
		const errors = strictErrorCount(source);
		assert item.accepted ? errors == 0 : errors > 0, source;
	}
	const statements = [
		{ source: "function f(b: boolean): int32 { let result: int32 = -1; match (b) { true => { result = 10; }, } return result; }", accepted: false },
		{ source: "function f(b: boolean): int32 { let result: int32 = -1; match (b) { true => { result = 10; }, false => { result = 20; }, } return result; }", accepted: true },
		{ source: "function f(n: int32): int32 { let result: int32 = -1; match (n) { 1 => { result = 10; }, } return result; }", accepted: false },
		{ source: "function f(n: int32): int32 { let result: int32 = -1; match (n) { 1 => { result = 10; }, _ => { result = 20; }, } return result; }", accepted: true },
	];
	for (const item of statements) {
		const parsedErrors = strictErrorCount(item.source);
		assert item.accepted ? parsedErrors == 0 : parsedErrors > 0, item.source;
		const nodeErrors = builtMatchErrors(item.source);
		assert item.accepted ? nodeErrors == 0 : nodeErrors > 0, item.source;
	}
	assert strictErrorCount("const PORT: int32 = 80; function f(port: int32): string { let name = \"unknown\"; match (port) { PORT => { name = \"http\"; }, } return name; }") > 0;
	assert strictErrorCount("function f(command: string): int32 { let hits: int32 = 0; match (command) { \"list\" => { hits += 1; }, \"show\" => { hits += 100; }, } return hits; }") == 0;
}

test "declaration boundaries: match arm returns follow the nearest value context" {
	const pre = "enum Failure { Rejected, TooBig } class Box { n: uint64 = 0; } ";
	const cases = [
		{ name: "ok payload in a returned block arm", source: "function f(value: uint32): Result<uint64, Failure> { return match (value) { 0 => { const result: uint64 = 7; return Result.ok(result); }, _ => Result.err(Failure.Rejected), }; }", accepted: true },
		{ name: "error payload in a returned block arm", source: "function f(value: uint32): Result<uint64, Failure> { return match (value) { 0 => Result.ok(5), _ => { return Result.err(Failure.TooBig); }, }; }", accepted: true },
		{ name: "nested return inherits the match value context", source: "function f(value: uint32): Result<uint64, Failure> { return match (value) { 0 => Result.err(Failure.Rejected), _ => { if (value > 10) { return Result.err(Failure.TooBig); } return Result.ok(2); }, }; }", accepted: true },
		{ name: "nested match arms use the inner declared context", source: "function f(value: uint32, flag: boolean): Result<uint64, Failure> { const outer: Result<uint64, Failure> = match (value) { 0 => { const inner: Result<uint64, Failure> = match (flag) { true => { return Result.ok(1); }, false => Result.err(Failure.Rejected), }; return inner; }, _ => Result.ok(9), }; return outer; }", accepted: true },
		{ name: "statement match returns leave the surrounding function", source: "function f(value: uint32): Result<uint64, Failure> { match (value) { 0 => { return Result.ok(3); }, _ => {}, }; return Result.err(Failure.Rejected); }", accepted: true },
		{ name: "statement match refuses a return outside the function relation", source: "function f(value: uint32): uint64 { match (value) { 0 => { return \"s\"; }, _ => {}, }; return 1; }", accepted: false },
		{ name: "match value nullability is independent of the function return", source: "function f(value: uint32): uint64 { const box: Box | null = match (value) { 0 => { return null; }, _ => new Box(), }; return box == null ? 0 : 1; }", accepted: true },
		{ name: "nested functions keep their own return context", source: "function f(value: uint32): string { return match (value) { 0 => { const next = (n: uint64): uint64 => { return n + 1; }; return `next ${next(41)}`; }, _ => \"other\", }; }", accepted: true },
	];
	for (const item of cases) {
		const c = compileToCWithStd(pre + item.source);
		assert c.ok == item.accepted, item.name + (c.ok ? "" : ": " + c.error);
	}
}

test "declaration boundaries: a wrong return in a statement match arm gets the diagnostic an if return gets" {
	const inMatch = compileToCWithStd("function f(value: uint32): uint64 { match (value) { 0 => { return \"s\"; }, _ => {}, }; return 1; }");
	const inIf = compileToCWithStd("function f(value: uint32): uint64 { if (value == 0) { return \"s\"; } return 1; }");
	assert !inMatch.ok;
	assert !inIf.ok;
	assert inMatch.error == inIf.error, inMatch.error + " | " + inIf.error;
}
