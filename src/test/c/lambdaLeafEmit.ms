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
