// injectdestructors.nim moveOrCopy: a `move x` into a borrowing parameter consumes nothing, whatever the shape around it,
// so the write that makes `x` readable again destroys the value `x` still holds.
// GUARD-BALANCE MbBox
// GUARD-JS

class MbBox { s: string; constructor(s: string) { this.s = s; } look(): int32 { return this.s.length; } }
struct MbS { s: string; }

function grow(b: MbBox): MbBox { return new MbBox(b.s + "+"); }
function look(b: MbBox): int32 { return b.s.length; }
function lookS(b: MbS): int32 { return b.s.length; }
function growS(b: MbS): MbS { return { s: b.s + "+" }; }
function relay(sink b: MbBox): int32 { return look(move b); }

function inBranch(c: boolean): string {
	let x = new MbBox("a");
	x = grow(move x);
	if (c) {
		const n = look(move x);
		x = new MbBox("b");
	}
	const y = move x;
	return y.s;
}

function receiver(): string {
	let x = new MbBox("a");
	x = grow(move x);
	const n = (move x).look();
	x = new MbBox("r");
	const y = move x;
	return y.s + n;
}

function valueStruct(): string {
	let x: MbS = { s: "a" };
	x = growS(move x);
	const n = lookS(move x);
	x = { s: "v" };
	const y = move x;
	return y.s + n;
}

function nestedCall(): string {
	let x = new MbBox("a");
	for (let i: int32 = 0; i < 2; i += 1) {
		if (i == 0) {
			const n = relay(move x);
			x = new MbBox("n");
		}
		x = grow(move x);
	}
	const y = move x;
	return y.s;
}

const got = inBranch(true) + " " + inBranch(false) + " " + receiver() + " " + valueStruct() + " " + nestedCall();
if (got == "b a+ r2 v2 n++") {
	console.log("GUARD-OK");
} else {
	console.log("GUARD-RED " + got);
	process.exit(1);
}
