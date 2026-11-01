// The parameter-write scan reaches every expression and statement kind, not a fixed
// list of statement shapes. A write it misses leaves Symbol.mutatedParams without the
// bit that makes C pass the parameter by a writable pointer.

import { compileToC } from "../helpers";

const SHAPE = "struct P { x: int64; y: int64; z: int64; w: int64; }\nconst fresh: P = { x: 9, y: 9, z: 9, w: 9 };\n";

function protoLine(c: string, name: string): string {
	for (const line of c.split("\n")) {
		if (line.startsWith("MS_LIB_PRIVATE") && line.contains(name + "__") && line.endsWith(";")) return line;
	}
	return "";
}

test "paramMutationScan: a parameter reassigned where the scan used to stop is passed as a writable pointer" {
	const cases = [
		{ name: "direct", body: "function direct(p: P): int64 { p = fresh; return p.x; }\nconsole.log(direct(fresh));" },
		{ name: "viaMatch", body: "function viaMatch(p: P, k: int32): int64 { match (k) { 1 => { p = fresh; }, _ => {}, }; return p.x; }\nconsole.log(viaMatch(fresh, 1));" },
		{ name: "viaMatchInLoop", body: "function viaMatchInLoop(p: P, k: int32): int64 { for (let i = 0; i < k; i++) { match (i) { 0 => { p = fresh; }, _ => {}, }; } return p.x; }\nconsole.log(viaMatchInLoop(fresh, 1));" },
		{ name: "viaArrow", body: "function viaArrow(p: P): int64 { const g = (): void => { p = fresh; }; g(); return p.x; }\nconsole.log(viaArrow(fresh));" },
		{ name: "viaFunctionExpr", body: "function viaFunctionExpr(p: P): int64 { const g = function (): void { p = fresh; }; g(); return p.x; }\nconsole.log(viaFunctionExpr(fresh));" },
		{ name: "viaForLocalFn", body: "function viaForLocalFn(p: P, k: int32): int64 { for (let i = 0; i < k; i++) { function g(): void { p = fresh; } g(); } return p.x; }\nconsole.log(viaForLocalFn(fresh, 1));" },
		{ name: "viaTryLocalFn", body: "function viaTryLocalFn(p: P): int64 { try { function g(): void { p = fresh; } g(); } catch (e) {} return p.x; }\nconsole.log(viaTryLocalFn(fresh));" },
		{ name: "viaSwitchLocalFn", body: "function viaSwitchLocalFn(p: P, k: int32): int64 { switch (k) { case 1: { function g(): void { p = fresh; } g(); break; } default: break; } return p.x; }\nconsole.log(viaSwitchLocalFn(fresh, 1));" },
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
