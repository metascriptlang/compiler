// @xfail(raiser): raiser runs no user lifecycle hooks (stdout misses its @stdout line)
// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: hooks ran fd fdArray fdField handle mapClass mapShared mapStruct name slot

struct Handle { h: int32; }
struct Slot<T> { v: T; }
struct Entry { id: int32; name: string; }
class Node { id: int32 = 0; label: string = "n"; }
class Shared { id: int32 = 0; label: string = "s"; }
type Fd = distinct int32;
type Name = distinct string;
struct Owner { fd: Fd; tag: string; }
struct FdCell { fd: Fd; }

let ran: string[] = [];

function note(what: string): void {
	if (!ran.includes(what)) ran.push(what);
}

function onDestroy(this x: Handle): void { note("handle"); }
function onDestroy<T>(this x: Slot<T>): void { note("slot"); }
function onDestroy(this x: Entry): void { note("mapStruct"); }
function onDestroy(this x: Node): void { note("mapClass"); }
function onDestroy(this x: Shared): void { note("mapShared"); }
function onDestroy(this x: Fd): void {
	const n = x as int32;
	if (n == 7) note("fd");
	if (n == 8) note("fdField");
	if (n == 9 || n == 10) note("fdArray");
}
function onDestroy(this x: Name): void { note("name"); }

function open(n: int32): Fd { return n as Fd; }
function label(s: string): Name { return s as Name; }

function handles(): void {
	const a: Handle = { h: 1 };
	const b: Slot<int32> = { v: 2 };
	console.log("handles " + a.h.toString() + b.v.toString());
}

function inMaps(): void {
	const entries = new Map<string, Entry>();
	entries.set("k", { id: 1, name: "a" });
	const nodes = new Map<string, Node>();
	nodes.set("k", new Node());
	console.log("maps " + entries.size.toString() + nodes.size.toString());
}

function inMapShared(): void {
	const first = new Shared();
	let second = new Shared();
	second = first;
	const shared = new Map<string, Shared>();
	shared.set("k", first);
	console.log("shared " + shared.size.toString() + second.id.toString());
}

function distincts(): void {
	const fd = open(7);
	const owner: Owner = { fd: open(8), tag: "t" };
	const cells: FdCell[] = [{ fd: open(9) }, { fd: open(10) }];
	const name = label("n" + owner.tag);
	console.log("distincts " + owner.tag + cells.length.toString());
}

handles();
inMaps();
inMapShared();
distincts();
ran.sort();
console.log("hooks ran " + ran.join(" "));
