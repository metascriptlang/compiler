// bug565 — a type argument named like a type of the generic's own module resolved to that module's type
//
// Symptom:    `wrap<Item>` from main, with `wrap<T>` in a lib that declares its own private `Item`, was refused
//             ("in instantiation of 'wrap<Item>': Argument type mismatch in 'push' arg 0: got Item, expected
//             Item"); the same in a method and a field initializer of a generic class.
//
// Root cause: the instance body is re-checked in the lib's scope, and its annotations were rewritten from `T`
//             to the type argument's NAME, which the lib's scope resolves to its own `Item`.
//
// Fix:        the body keeps `T`, and the instance scope binds `T` to the type argument itself; each instance
//             records its type arguments, and the macro engine binds them when it recompiles the instance.

import { checkProjectDiagnostics, MapEntry } from "../helpers";

const LIB565 = `interface Item { a: int32; }

export function wrap<T>(x: T): T[] {
	const out: T[] = [];
	out.push(x);
	return out;
}

export function pairWith<T>(x: T): int32 {
	const own: Item = { a: 1 as int32 };
	const xs: T[] = [x];
	return own.a + (xs.length as int32);
}

export class Shelf<T> {
	byName: Map<string, T> = new Map<string, T>();
	constructor() {}
	put(k: string, v: T): void {
		const kept: T[] = [v];
		this.byName.set(k, kept[0]);
	}
}
`;

function diagnostics565(mainSource: string): string {
	const entries: MapEntry[] = [
		{ entryPath: "src/lib.ms", entrySource: LIB565 },
		{ entryPath: "src/main.ms", entrySource: mainSource },
	];
	return checkProjectDiagnostics(entries, "src/main.ms").join("\n");
}

const MAIN_ITEM = `interface Item { name: string; }\n`;

test "bug565: a generic function's body binds T to the caller's type, not the lib's same-named one" {
	const d = diagnostics565(`import { wrap } from "./lib";\n${MAIN_ITEM}const xs = wrap<Item>({ name: "a" });\nconst n: string = xs[0].name;\n`);
	assert d == "", d;
}

test "bug565: a body naming its own module's type keeps it beside T" {
	const d = diagnostics565(`import { pairWith } from "./lib";\n${MAIN_ITEM}const n: int32 = pairWith<Item>({ name: "a" });\n`);
	assert d == "", d;
}

test "bug565: a generic class method binds T to the caller's type" {
	const d = diagnostics565(`import { Shelf } from "./lib";\n${MAIN_ITEM}const s = new Shelf<Item>();\ns.put("k", { name: "a" });\n`);
	assert d == "", d;
}

test "bug565: a generic class field initializer binds T to the caller's type" {
	const d = diagnostics565(`import { Shelf } from "./lib";\n${MAIN_ITEM}const s = new Shelf<Item>();\nconst n: number = s.byName.size;\n`);
	assert d == "", d;
}
