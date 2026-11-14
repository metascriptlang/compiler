// Emitted C of a checked element-store loop run in sticky blocks; src/test/corpus/programs/blockStore*.ms and lambdaLeafStops run them.

import { builtModuleC } from "../helpers";

function built(name: string, body: string): string {
	const source = `function f(a: int32[], b: int32[], k: int32): int32[] {\n\t${body}\n}\nconsole.log(f([1, 2, 3], [4, 5, 6], 3).length);\n`;
	return builtModuleC("blockStoreEmit", name, source, ["--release"]);
}

test "E2E C: a checked store of each element into another array, under one bound or two, runs in sticky blocks guarded against a shared array" {
	const bodies: string[] = [
		"return a.values().map((x) => x * 2).toArray();",
		"for (let i = 0; i < a.length; i++) b[i] = a[i] + k; return b;",
		"for (let i = 0; i < a.length; i++) { const t = a[i] ^ k; b[i] = t * 3; } return b;",
		"for (let i = 0; i < k && i < a.length; i++) b[i] = a[i] + k; return b;",
		"return a.map((x) => x * 2);",
	];
	for (const body of bodies) {
		const c = built("sticky", body);
		assert !c.startsWith("error:"), c.slice(0, 400);
		assert c.contains("msBlockSameData("), body;
	}
}

test "E2E C: a store loop that reads the array it writes, stores off its index, or calls keeps the checked loop alone" {
	const bodies: string[] = [
		"for (let i = 0; i < a.length; i++) a[i] = a[i] * 2; return a;",
		"for (let i = 0; i + 1 < a.length; i++) a[i] = a[i + 1] * 2; return a;",
		"for (let i = 0; i + 1 < a.length; i++) b[i + 1] = a[i] * 2; return b;",
		"for (let i = 0; i < a.length; i++) b[i] = a[i] * String(k).length; return b;",
	];
	for (const body of bodies) {
		const c = built("checked", body);
		assert !c.startsWith("error:"), c.slice(0, 400);
		assert !c.contains("msBlockSameData("), body;
	}
}
