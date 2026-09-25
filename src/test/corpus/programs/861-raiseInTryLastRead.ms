// @stdout: nested catch one
// note: a throw inside try, or a call there that can raise, reaches the handler in the last-read analysis. It used to jump to the function end, so a value copied just before was moved away and the catch read it empty or null.

class Box { v: string; constructor(v: string) { this.v = v; } }

function mk(s: string): string { return s + "!"; }
function boom(): void { throw new Error("boom"); }

function throwStmt(): void {
	let x = mk("a");
	try {
		let y = x;
		y = y + "?";
		console.log("y=" + y);
		throw new Error("boom");
	} catch (e) {
		console.log("x=" + x);
	}
}

function throwAfterHold(): void {
	const b = new Box("one");
	let hold: Box | null = null;
	try {
		hold = b;
		throw new Error("boom");
	} catch (e) {
		console.log("catch " + b.v);
	}
	if (hold != null) console.log("hold " + hold.v);
}

function raisingCallThenWrite(): void {
	let b = new Box("one");
	let hold: Box | null = null;
	try {
		hold = b;
		boom();
		b = new Box("two");
	} catch (e) {
		console.log("catch " + b.v);
	}
	if (hold != null) console.log("hold " + hold.v);
}

function nestedFinallyOnly(): void {
	const b = new Box("one");
	let hold: Box | null = null;
	try {
		try {
			hold = b;
			throw new Error("boom");
		} finally {
			console.log("inner finally");
		}
	} catch (e) {
		console.log("nested catch " + b.v);
	}
	if (hold != null) console.log("hold " + hold.v);
}

throwStmt();
throwAfterHold();
raisingCallThenWrite();
nestedFinallyOnly();
