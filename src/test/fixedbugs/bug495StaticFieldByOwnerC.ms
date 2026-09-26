// bug495 — same-named classes in two modules shared their static field globals on C
//
// Symptom:    a.ms and b.ms both `export class Counter { static total: int32 }`: the link failed
//             with `duplicate symbol: Counter__total`; JS printed `2 200`.
// Root cause: collect created a class's static field symbols without an owner module (methods
//             got one), so the C global name had no module qualifier to tell the two apart.
// Fix:        a static field symbol carries its module, and its C global name is qualified by it
//             at the definition and at every read.

import { compileProjectToC, MapEntry } from "../helpers";

const A = "export class Counter {\n\tstatic total: int32 = 1;\n\tstatic label: string = \"a\";\n}\nexport function getA(): int32 { Counter.total = Counter.total + 1; return Counter.total; }\n";
const B = "export class Counter {\n\tstatic total: int32 = 100;\n}\nexport function getB(): int32 { Counter.total = Counter.total + 100; return Counter.total; }\n";
const MAIN = "import { getA } from \"./a\";\nimport { getB } from \"./b\";\nconsole.log(getA(), getB());\n";

function entries(main: string): MapEntry[] {
	return [
		{ entryPath: "bug495/a.ms", entrySource: A },
		{ entryPath: "bug495/b.ms", entrySource: B },
		{ entryPath: "bug495/main.ms", entrySource: main },
	];
}

function definitions(c: string, prefix: string): string[] {
	const found: string[] = [];
	let at = c.indexOf(`int32_t ${prefix}`, 0);
	while (at >= 0) {
		const eol = c.indexOf(";", at);
		const name = c.slice(at + 8, eol > 0 ? eol : c.byteLength);
		if (!found.includes(name)) found.push(name);
		at = c.indexOf(`int32_t ${prefix}`, at + 1);
	}
	return found;
}

test "bug495: two modules' static fields of one class name get two C globals" {
	const c = compileProjectToC(entries(MAIN), "bug495/main.ms");
	assert !c.startsWith("ERROR:");
	const names = definitions(c, "Counter__total");
	assert names.length == 2;
	assert !names.includes("Counter__total");
}

test "bug495: a static read from the importing module names the owner's global" {
	const main = "import { Counter } from \"./a\";\nimport { getB } from \"./b\";\nCounter.total = Counter.total + 10;\nconsole.log(Counter.total, Counter.label, getB());\n";
	const c = compileProjectToC(entries(main), "bug495/main.ms");
	assert !c.startsWith("ERROR:");
	assert !c.contains(" Counter__total;");
	assert !c.contains("(Counter__total ");
}
