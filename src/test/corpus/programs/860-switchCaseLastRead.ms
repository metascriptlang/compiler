// @stdout: [one2] [one2]
// note: each case of an int switch is its own path for last-read analysis. A write in one case used to hide a read in another, so a value copied before the switch was moved away and the reading case saw it empty or null.

class Box { v: string; constructor(v: string) { this.v = v; } }
interface Rec { s: string; }

function mk(s: string): string { return s + "!"; }
function mkRec(s: string): Rec { return { s: s + "!" }; }

function writeThenRead(k: int32): void {
	let x = mk("a");
	const y = x;
	switch (k) {
		case 1: x = mk("b"); break;
		case 2: console.log("x=" + x); break;
	}
	console.log("y=" + y);
}

function readInDefault(k: int32): void {
	let x = mkRec("a");
	const y = x;
	switch (k) {
		case 1: x = mkRec("b"); break;
		default: console.log("x=" + x.s); break;
	}
	console.log("y=" + y.s);
}

function writeInDefault(k: int32): void {
	let s = "one" + String(k);
	const prev = s;
	switch (k) {
		case 1: console.log("k=1"); break;
		default: s = "other"; break;
	}
	console.log("[" + prev + "] [" + s + "]");
}

function laterCaseWrites(k: int32): void {
	let s = "one" + String(k);
	const prev = s;
	switch (k) {
		case 1: s = "two"; break;
		case 2: console.log("k=2"); break;
	}
	console.log("[" + prev + "] [" + s + "]");
}

function viaMatch(k: int32): void {
	let b = new Box("one");
	let hold: Box | null = null;
	match (k) {
		1 => { hold = b; },
		2 => { b = new Box("two"); },
		_ => {},
	}
	console.log(b.v);
	if (hold != null) console.log("hold " + hold.v);
}

writeThenRead(2);
readInDefault(2);
writeInDefault(1);
writeInDefault(2);
laterCaseWrites(1);
laterCaseWrites(2);
viaMatch(1);
viaMatch(2);
