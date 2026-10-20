// nim-guard: evicting `Arc`/`Locked` cells from an array takes them out of the array before it
// releases them, so the payload's onDestroy that walks the array never finds its own cell or one
// released before it.
//
// An atomic cell's payload is plain or deep-immutable data, yet a struct of plain fields still
// declares onDestroy, and the cell's release runs it. Nim's seq shrink resets each evicted slot and
// lowers the length afterwards (system/seqs_v2.nim shrink), and its delete overwrites through a
// sink that releases first (system.nim delete); NIM-REF records the forced divergence: the hook
// walked into its own dying cell and destroyed it again (ledger DOUBLE-DESTROY on MS).
//
// RED MEANS a hook found its own cell or a released one still in the array, or the walk destroyed
// a cell twice. The many-cells case deletes more than the runtime keeps inline.
// GUARD-BALANCE TOTAL

import { lockedRead } from "std/core/promise";

struct Mark {
	tag: int32;
}

function onDestroy(this m: Mark): void {
	if (!watching) return;
	watching = false;
	const seen = viewer();
	watching = true;
	if (seen.contains(`<${m.tag}>`)) failures = `${failures}${what}: the hook of ${m.tag} found itself in ${seen}; `;
	for (const g of gone) {
		if (seen.contains(`<${g}>`)) failures = `${failures}${what}: the hook of ${m.tag} found released ${g} in ${seen}; `;
	}
	gone.push(m.tag);
}

let watching = false;
let what = "";
let gone: int32[] = [];
let failures = "";
let viewer: () => string = (): string => "";

let arcs: Arc<Mark>[] = [];
let cells: Locked<Mark>[] = [];

function arcTags(): string {
	let s = "";
	for (let i = 0; i < arcs.length; i++) s = `${s}<${arcs[i].tag}>`;
	return s;
}

function cellTags(): string {
	let s = "";
	for (let i = 0; i < cells.length; i++) s = `${s}<${lockedRead(cells[i], (v: Mark): int32 => v.tag)}>`;
	return s;
}

function arcsOf(n: int32): Arc<Mark>[] {
	const a: Arc<Mark>[] = [];
	for (let i: int32 = 1; i <= n; i++) a.push(new Arc<Mark>({ tag: i }));
	return a;
}

function cellsOf(n: int32): Locked<Mark>[] {
	const a: Locked<Mark>[] = [];
	for (let i: int32 = 1; i <= n; i++) a.push(new Locked<Mark>({ tag: i }));
	return a;
}

function start(name: string): void {
	what = name;
	gone = [];
	watching = true;
}

function expect(released: int32, final: string): void {
	watching = false;
	const now = viewer();
	if (gone.length != released) failures = `${failures}${what}: released ${gone.length}, want ${released}; `;
	if (now != final) failures = `${failures}${what}: left ${now}, want ${final}; `;
}

function replaceFirst<T>(a: T[], x: T): void {
	a.splice(0, 1, x);
}

function arcSplice(): void {
	arcs = arcsOf(3);
	const item = new Arc<Mark>({ tag: 9 });
	start("arc cells replaced");
	arcs.splice(0, 2, item);
	expect(2, "<9><3>");
}

function lockedSplice(): void {
	cells = cellsOf(3);
	const item = new Locked<Mark>({ tag: 9 });
	start("locked cells replaced");
	cells.splice(1, 1, item);
	expect(1, "<1><9><3>");
}

function lockedSpliceMany(): void {
	cells = cellsOf(12);
	const item = new Locked<Mark>({ tag: 99 });
	start("many locked cells replaced");
	cells.splice(1, 10, item);
	expect(10, "<1><99><12>");
}

function arcSpliceGeneric(): void {
	arcs = arcsOf(3);
	const item = new Arc<Mark>({ tag: 9 });
	start("generic body");
	replaceFirst(arcs, item);
	expect(1, "<9><2><3>");
}

function arcEmpty(): void {
	arcs = arcsOf(3);
	start("arc cells emptied");
	arcs.length = 0;
	expect(3, "");
}

function lockedEmpty(): void {
	cells = cellsOf(2);
	start("locked cells emptied");
	cells.length = 0;
	expect(2, "");
}

viewer = arcTags;
arcSplice();
arcSpliceGeneric();
arcEmpty();
arcs = [];
viewer = cellTags;
lockedSplice();
lockedSpliceMany();
lockedEmpty();
cells = [];

if (failures != "") throw new Error(failures);
console.log("atomic cells leave the array before release");
