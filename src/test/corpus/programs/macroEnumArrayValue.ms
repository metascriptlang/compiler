// @stdout: index=1,2 forOf=12 compare=0,1 int=1,2 ternary=1,2,2 explicit=7,11|1 field=12
// note: an enum array literal in a function a macro calls hands back its elements' values: read by index, by for-of and by `as int32`, compared with `==`, stored into a field, and an unannotated local of an enum ternary; an int array is the control, and an enum with explicit values keeps its own numbers.

import { Node, NodeKind } from "std/meta";

enum Kind { F, I, U, B }
enum E { X = 3, Y = 7, Z = 11 }
struct Holder { k: Kind; }

function viaIndex(i: int32): int32 {
	const scalars = [Kind.I, Kind.U];
	return scalars[i] as int32;
}
function viaForOf(): string {
	let s = "";
	for (const k of [Kind.I, Kind.U]) { s += String(k as int32); }
	return s;
}
function viaCompare(k: Kind): int32 {
	const kinds = [Kind.I, Kind.U];
	for (let i = 0; i < kinds.length; i++) { if (kinds[i] == k) { return i as int32; } }
	return -1;
}
function intArray(i: int32): int32 { const xs = [1, 2]; return xs[i]; }
function bare(i: int32): int32 { const k = i == 0 ? Kind.I : Kind.U; return k as int32; }
function explicitAt(i: int32): int32 { const es = [E.Y, E.Z]; return es[i] as int32; }
function explicitFind(e: E): int32 {
	const es = [E.X, E.Y, E.Z];
	for (let i = 0; i < es.length; i++) { if (es[i] == e) { return i as int32; } }
	return -1;
}
function field(): int32 {
	const kinds = [Kind.I, Kind.U];
	const h: Holder = { k: kinds[1] };
	return (kinds[0] as int32) * 10 + (h.k as int32);
}

macro table(): Node {
	const s = "index=" + String(viaIndex(0)) + "," + String(viaIndex(1)) + " forOf=" + viaForOf()
		+ " compare=" + String(viaCompare(Kind.I)) + "," + String(viaCompare(Kind.U))
		+ " int=" + String(intArray(0)) + "," + String(intArray(1))
		+ " ternary=" + String(bare(0)) + "," + String(bare(1)) + "," + String(bare(5))
		+ " explicit=" + String(explicitAt(0)) + "," + String(explicitAt(1)) + "|" + String(explicitFind(E.Y))
		+ " field=" + String(field());
	return { kind: NodeKind.StringLiteral, line: 1, column: 1, value: s };
}

console.log(table());
