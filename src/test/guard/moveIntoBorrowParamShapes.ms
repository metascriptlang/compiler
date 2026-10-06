// injectdestructors.nim moveOrCopy: a `move x` into a borrowing parameter consumes nothing, whatever the shape around it.
// GUARD-BALANCE MbBox
// GUARD-JS

class MbBox { s: string; constructor(s: string) { this.s = s; } look(): int32 { return this.s.length; } }
struct MbS { s: string; }

function grow(b: MbBox): MbBox { return new MbBox(b.s + "+"); }
function look(b: MbBox): int32 { return b.s.length; }
function lookS(b: MbS): int32 { return b.s.length; }
function growS(b: MbS): MbS { return { s: b.s + "+" }; }
function relay(b: MbBox): int32 { return look(move b); }

function inBranch(c: boolean): string {
	let x = new MbBox("a");
	x = grow(move x);
	if (c) {
		const n = look(move x);
		x = grow(move x);
	}
	const y = move x;
	return y.s;
}

function receiver(): string {
	let x = new MbBox("a");
	x = grow(move x);
	const n = (move x).look();
	const y = move x;
	return y.s + n;
}

function valueStruct(): string {
	let x: MbS = { s: "a" };
	x = growS(move x);
	const n = lookS(move x);
	const y = move x;
	return y.s + n;
}

function nestedCall(): string {
	let x = new MbBox("a");
	for (let i: int32 = 0; i < 2; i += 1) {
		if (i == 0) {
			const n = relay(move x);
		}
		x = grow(move x);
	}
	const y = move x;
	return y.s;
}

const got = inBranch(true) + " " + inBranch(false) + " " + receiver() + " " + valueStruct() + " " + nestedCall();
if (got == "a++ a+ a+2 a+2 a++") {
	console.log("GUARD-OK");
} else {
	console.log("GUARD-RED " + got);
	process.exit(1);
}
