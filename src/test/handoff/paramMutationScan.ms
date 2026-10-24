// The parameter-write scan reaches every expression and statement kind, not a fixed
// list of statement shapes. A write it misses leaves Symbol.mutatedParams without the
// bit that makes C pass the parameter by a writable pointer, and lets a readonly
// parameter be written without the refusal.

import { compileToC, refusedOnEveryBackend } from "../helpers";

const SHAPE = "struct P { x: int64; y: int64; z: int64; w: int64; }\nconst fresh: P = { x: 9, y: 9, z: 9, w: 9 };\n";

function protoLine(c: string, name: string): string {
	for (const line of c.split("\n")) {
		if (line.startsWith("MS_LIB_PRIVATE") && line.contains(name + "__") && line.endsWith(";")) return line;
	}
	return "";
}

test "paramMutationScan: a readonly parameter written where the scan used to stop is refused" {
	const writes = [
		{ name: "a match arm", body: "function f(readonly p: P, k: int32): int64 { match (k) { 1 => { p = fresh; }, _ => {}, }; return p.x; }", call: "f(fresh, 1)" },
		{ name: "a compound assignment in a match arm", body: "function f(readonly n: int32, k: int32): int32 { match (k) { 1 => { n += 1; }, _ => {}, }; return n; }", call: "f(1, 1)" },
		{ name: "an arrow body", body: "function f(readonly p: P): int64 { const g = (): void => { p = fresh; }; g(); return p.x; }", call: "f(fresh)" },
		{ name: "an update in an arrow body", body: "function f(readonly n: int32): int32 { const g = (): void => { n++; }; g(); return n; }", call: "f(1)" },
		{ name: "a function expression body", body: "function f(readonly p: P): int64 { const g = function (): void { p = fresh; }; g(); return p.x; }", call: "f(fresh)" },
		{ name: "a local function declared in a for body", body: "function f(readonly p: P, k: int32): int64 { for (let i = 0; i < k; i++) { function g(): void { p = fresh; } g(); } return p.x; }", call: "f(fresh, 1)" },
		{ name: "a local function declared in a try body", body: "function f(readonly p: P): int64 { try { function g(): void { p = fresh; } g(); } catch (e) {} return p.x; }", call: "f(fresh)" },
		{ name: "a local function declared in a switch case", body: "function f(readonly p: P, k: int32): int64 { switch (k) { case 1: { function g(): void { p = fresh; } g(); break; } default: break; } return p.x; }", call: "f(fresh, 1)" },
	];
	for (const w of writes) {
		const verdict = refusedOnEveryBackend(SHAPE + w.body + "\nconsole.log(" + w.call + ");", "cannot mutate readonly parameter");
		assert verdict == "", w.name + ": " + verdict;
	}
}

test "paramMutationScan: a write the scan always saw is still refused" {
	const verdict = refusedOnEveryBackend(SHAPE + "function f(readonly p: P): int64 { p = fresh; return p.x; }\nconsole.log(f(fresh));", "cannot mutate readonly parameter 'p'");
	assert verdict == "", verdict;
}

test "paramMutationScan: a readonly parameter only read in those places stays accepted" {
	const c = compileToC(SHAPE + "function f(readonly p: P, k: int32): int64 { const g = (): int64 => p.x; match (k) { 1 => { const q = p.y; }, _ => {}, }; return g(); }\nconsole.log(f(fresh, 1));");
	assert c.ok, c.ok ? "" : c.error;
}

test "paramMutationScan: a parameter reassigned where the scan used to stop is passed as a writable pointer" {
	const cases = [
		{ name: "direct", body: "function direct(p: P): int64 { p = fresh; return p.x; }\nconsole.log(direct(fresh));" },
		{ name: "viaMatch", body: "function viaMatch(p: P, k: int32): int64 { match (k) { 1 => { p = fresh; }, _ => {}, }; return p.x; }\nconsole.log(viaMatch(fresh, 1));" },
		{ name: "viaMatchInLoop", body: "function viaMatchInLoop(p: P, k: int32): int64 { for (let i = 0; i < k; i++) { match (i) { 0 => { p = fresh; }, _ => {}, }; } return p.x; }\nconsole.log(viaMatchInLoop(fresh, 1));" },
		{ name: "viaArrow", body: "function viaArrow(p: P): int64 { const g = (): void => { p = fresh; }; g(); return p.x; }\nconsole.log(viaArrow(fresh));" },
		{ name: "viaFunctionExpr", body: "function viaFunctionExpr(p: P): int64 { const g = function (): void { p = fresh; }; g(); return p.x; }\nconsole.log(viaFunctionExpr(fresh));" },
	];
	for (const item of cases) {
		const c = compileToC(SHAPE + item.body);
		assert c.ok, item.name + ": " + (c.ok ? "" : c.error);
		const line = protoLine(c.value, item.name);
		assert line != "", item.name + ": no prototype";
		assert !line.contains("const P__"), item.name + ": " + line;
	}
}

test "paramMutationScan: a parameter that is only read stays a const pointer" {
	const c = compileToC(SHAPE + "function viaMatch(p: P, k: int32): int64 { const g = (): int64 => p.x; match (k) { 1 => { const q = p.y; }, _ => {}, }; return g(); }\nconsole.log(viaMatch(fresh, 1));");
	assert c.ok, c.ok ? "" : c.error;
	const line = protoLine(c.value, "viaMatch");
	assert line.contains("const P__"), line;
}
