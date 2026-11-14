// Emitted C of a call through a const binding of a pure leaf arrow; src/test/corpus/programs/lambdaLeafStops.ms runs one.

import { builtModuleC } from "../helpers";

function built(name: string, body: string): string {
	const source = `function f(a: int32[], k: int32): int32[] {\n\t${body}\n}\nconsole.log(f([1, 2, 3], 3).length);\n`;
	return builtModuleC("lambdaLeafEmit", name, source, ["--release"]);
}

const INDIRECT = ".fn)(";

test "E2E C: a map callback that is a pure leaf arrow runs inline in the store loop" {
	const bodies: string[] = [
		"return a.values().map((x) => x * 2).toArray();",
		"return a.values().map((x) => { return (x ^ 7) + 1; }).toArray();",
		"const g = (x: int32): int32 => x - 1; const out: int32[] = []; for (const x of a) out.push(g(x)); return out;",
	];
	for (const body of bodies) {
		const c = built("inline", body);
		assert !c.startsWith("error:"), c.slice(0, 400);
		assert !c.contains(INDIRECT), body;
	}
}

test "E2E C: a capturing, multi-statement, reassigned or non-word callback stays a call" {
	const bodies: string[] = [
		"return a.values().map((x) => x * k).toArray();",
		"return a.values().map((x) => { const y = x * 2; return y + 1; }).toArray();",
		"let g = (x: int32): int32 => x - 1; if (k > 5) g = (x: int32): int32 => x + 1; const out: int32[] = []; for (const x of a) out.push(g(x)); return out;",
		"return a.values().map((x) => String(x).length as int32).toArray();",
	];
	for (const body of bodies) {
		const c = built("call", body);
		assert !c.startsWith("error:"), c.slice(0, 400);
		assert c.contains(INDIRECT), body;
	}
}

test "E2E C: an @inline array method given a pure leaf arrow runs in place with the arrow inline, and its map and sum run in sticky blocks" {
	const fn = "function g(a: int32[], k: int32): int32 { return a.map((x) => x * 2).filter((x) => x % 3 != 0).reduce((acc: int32, x) => acc + x, 0 as int32); }";
	const c = builtModuleC("lambdaLeafEmit", "eager", `${fn}\nconsole.log(g([1, 2, 3], 3));\n`, ["--release"]);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert !c.contains(INDIRECT), fn;
	assert c.contains("msBlockRangeFits("), fn;
	assert c.contains("msBlockSameData("), fn;
	const capturing = "function g(a: int32[], k: int32): int32 { return a.map((x) => x * k).reduce((acc: int32, x) => acc + x, 0 as int32); }";
	const kept = builtModuleC("lambdaLeafEmit", "eagercall", `${capturing}\nconsole.log(g([1, 2, 3], 3));\n`, ["--release"]);
	assert !kept.startsWith("error:"), kept.slice(0, 400);
	assert kept.contains(INDIRECT), capturing;
}
