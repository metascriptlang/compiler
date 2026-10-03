// Route 15j: Checker — the Maybe carrier of a function payload is keyed by the whole payload, pointees included

import { strictErrorCount } from "./helpers";
import { compileToC } from "../helpers";

const SRC = "interface Box { w: number; }\ninterface Pt { x: number; }\n"
	+ "function pick<T>(fn: () => T, equals: ((a: T, b: T) => boolean) | null = null): T { const v = fn(); if (equals !== null && equals(v, v)) { return v; } return v; }\n";
const BOX = "const b = pick((): Box => { const o: Box = { w: 1 }; return o; });\n";
const PT = "const p = pick((): Pt => { const o: Pt = { x: 2 }; return o; });\n";

test "two struct instantiations of a nullable function formal each check against their own pointee" {
	assert strictErrorCount(SRC + BOX + PT) == 0;
	assert strictErrorCount(SRC + PT + BOX) == 0;
}

test "a primitive instantiation before the struct ones changes nothing" {
	assert strictErrorCount(SRC + "const n = pick((): number => 1);\n" + BOX + PT) == 0;
}

const NULLABLE_STRUCT_IN_SLOT = `
struct Box { names: string[]; count: int32; }
interface Slot { got: Box | null; }
function get(slot: Slot): Box {
	if (slot.got == null) return { names: [], count: 0 };
	return slot.got as Box;
}
`;
const NULLABLE_STRUCT_IN_CLOSURE = `
struct Box { names: string[]; count: int32; }
function get(): Box {
	let got: Box | null = null;
	const fill = (): void => { got = { names: ["a"], count: 1 }; };
	fill();
	if (got == null) return { names: [], count: 0 };
	return got!;
}
`;
const NULLABLE_STRUCT_COUNT = `
struct Box { names: string[]; count: int32; }
function pick(b: Box | null): int32 { return b == null ? 0 : b!.count; }
`;
const NULLABLE_STRUCT_TOTAL = `
struct Box { total: int64; }
function pick(b: Box | null): int64 { return b == null ? 0 : b!.total; }
function wrap(x: Box): Box | null { return x; }
`;
const NULLABLE_BITSET = `
enum E { A, B, C }
const some: BitSet<E> = E.A | E.C;
function pick(on: boolean): BitSet<E> | null { return on ? some : null; }
console.log(pick(true) != null);
`;
const NULLABLE_GENERIC_STRUCT = `
struct Pair<T> { a: T; b: T; }
const two: Pair<int32> = { a: 1, b: 2 };
function pair(on: boolean): Pair<int32> | null { return on ? two : null; }
console.log(pair(true) != null);
`;

test "a T | null carrier answers only for the payload declaration it was built from" {
	const compilations = [
		{
			name: "a struct declared again with the same fields",
			first: NULLABLE_STRUCT_IN_SLOT,
			second: NULLABLE_STRUCT_IN_CLOSURE,
		},
		{
			name: "a struct declared again with other fields",
			first: NULLABLE_STRUCT_COUNT,
			second: NULLABLE_STRUCT_TOTAL,
		},
		{
			name: "a BitSet over an enum declared again",
			first: NULLABLE_BITSET,
			second: NULLABLE_BITSET,
		},
		{
			name: "a generic struct instance whose generic is declared again",
			first: NULLABLE_GENERIC_STRUCT,
			second: NULLABLE_GENERIC_STRUCT,
		},
	];
	for (const item of compilations) {
		const first = compileToC(item.first);
		assert first.ok, item.name + (first.ok ? "" : ": " + first.error);
		const second = compileToC(item.second);
		assert second.ok, item.name + (second.ok ? "" : ": " + second.error);
	}
}
