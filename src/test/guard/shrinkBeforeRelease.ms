// nim-guard: cutting an array with `length = n` takes each evicted element out of the array before
// it releases it, so an onDestroy run by that release that walks the array never finds itself.
//
// Nim's seq shrink resets each evicted slot and lowers the length afterwards (system/seqs_v2.nim
// shrink, countdown); NIM-REF records the forced divergence: the hook found its own dying
// element still in the array, and a slot already cleared to nil under a non-nullable element
// type crashed the walk (ASan SEGV on MS).
//
// RED MEANS a hook found the element being released still in the array, or the walk crashed on
// a cleared slot.

class Witness {
	tag: int32;
	constructor(tag: int32) { this.tag = tag; }
	onDestroy(): void {
		if (findsItself(this.tag)) failures = `${failures}${what}: the hook of ${this.tag} found itself in the array; `;
		released = released + 1;
	}
}

let what = "";
let released: int32 = 0;
let failures = "";
let searching = "";

function expectReleased(n: int32): void {
	if (released != n) failures = `${failures}${what}: released ${released}, want ${n}; `;
	searching = "";
}

let ws: Witness[] = [];
let maybeWs: (Witness | null)[] = [];

function findsItself(tag: int32): boolean {
	if (searching == "ws") {
		for (const w of ws) if (w.tag == tag) return true;
	} else if (searching == "maybeWs") {
		for (const w of maybeWs) if (w != null && w.tag == tag) return true;
	}
	return false;
}

function start(name: string): void {
	what = name;
	released = 0;
}

function refArrayEmpty(): void {
	ws = [new Witness(1), new Witness(2)];
	start("ref array emptied");
	searching = "ws";
	ws.length = 0;
	expectReleased(2);
}

function nullableRefArrayCut(): void {
	maybeWs = [new Witness(1), new Witness(2), new Witness(3)];
	start("nullable ref array cut");
	searching = "maybeWs";
	maybeWs.length = 1;
	expectReleased(2);
	maybeWs.length = 0;
}

refArrayEmpty();
nullableRefArrayCut();
if (failures != "") throw new Error(failures);
console.log("arrays cut before release");
