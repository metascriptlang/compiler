// Language tests: try/catch/finally + throw

function mayThrow(x: number): number {
	if (x < 0) throw "negative";
	return x * 2;
}

test "basic try/catch — no throw" {
	let r: number = 0;
	try {
		r = mayThrow(5);
	} catch (e) {
		r = -1;
	}
	assert r == 10;
}

test "basic try/catch — throws" {
	let r: number = 0;
	try {
		r = mayThrow(-1);
	} catch (e) {
		r = -1;
	}
	assert r == -1;
}

test "finally — no throw" {
	let log = "";
	try {
		log = log + "try,";
	} catch (e) {
		log = log + "catch,";
	} finally {
		log = log + "finally";
	}
	assert log == "try,finally";
}

test "finally — with throw" {
	let log = "";
	try {
		log = log + "try,";
		throw "oops";
	} catch (e) {
		log = log + "catch,";
	} finally {
		log = log + "finally";
	}
	assert log == "try,catch,finally";
}

test "nested try/catch" {
	let inner = "";
	let outer = "";
	try {
		outer = "outer-try";
		try {
			inner = "inner-try";
			throw "inner-err";
		} catch (e) {
			inner = "inner-caught";
		}
	} catch (e) {
		outer = "outer-caught";
	}
	assert inner == "inner-caught";
	assert outer == "outer-try";
}

test "throw propagates through finally" {
	let caught = "";
	try {
		try {
			throw "deep";
		} finally {
			// finally runs but doesn't catch
		}
	} catch (e) {
		caught = "got-it";
	}
	assert caught == "got-it";
}

test "throw new Error — caught" {
	let r = 0;
	try {
		throw new Error("boom");
	} catch (e) {
		r = 42;
	}
	assert r == 42;
}

test "throw new Error — propagates through finally" {
	let log = "";
	try {
		try {
			throw new Error("deep");
		} finally {
			log = log + "finally";
		}
	} catch (e) {
		log = log + ",caught";
	}
	assert log == "finally,caught";
}

function raiseAbove(n: int32, limit: int32): int32 {
	if (n > limit) throw new Error("above");
	return n;
}

function returnCall(n: int32): int32 {
	try { return raiseAbove(n, 1); } catch (e) { }
	return -1;
}

function returnOperand(n: int32): int32 {
	try { return raiseAbove(n, 1) + 10; } catch (e) { }
	return -1;
}

function textAbove(n: int32, limit: int32): string {
	if (n > limit) throw new Error("above");
	return "n=" + n.toString();
}

function returnText(n: int32): string {
	try { return textAbove(n, 1); } catch (e) { }
	return "caught";
}

let finallyRuns = 0;
function countFinally(): void { finallyRuns += 1; }

function returnThroughFinally(n: int32): int32 {
	try { return raiseAbove(n, 1); } finally { countFinally(); }
}

test "a raise in a return value inside try reaches the catch" {
	assert returnCall(1) == 1;
	assert returnCall(2) == -1;
}

test "a raise in a return operand inside try reaches the catch" {
	assert returnOperand(1) == 11;
	assert returnOperand(2) == -1;
}

test "a raise in a returned string inside try reaches the catch" {
	assert returnText(1) == "n=1";
	assert returnText(2) == "caught";
}

test "a raise in a return value runs the finally once" {
	finallyRuns = 0;
	let caught = false;
	try { returnThroughFinally(2); } catch (e) { caught = true; }
	assert caught;
	assert finallyRuns == 1;
}

function label(n: number): string {
	return `label ${n}`;
}

test "a thrown string reaches catch as an Error carrying it" {
	let msg = "";
	let isError = false;
	try {
		throw "bare 7";
	} catch (e) {
		msg = e.message;
		isError = e instanceof Error;
	}
	assert msg == "bare 7";
	assert isError;
}

test "a thrown string variable and template reach catch as Errors" {
	const s = label(3);
	let log = "";
	try { throw s; } catch (e) { log = e.message; }
	try { throw `${s}!`; } catch (e) { log = log + "," + e.message; }
	assert log == "label 3,label 3!";
}

test "a thrown string rethrown keeps its message" {
	let msg = "";
	try {
		try { mayThrow(-1); } catch (e) { throw e; }
	} catch (e2) {
		msg = e2.message;
	}
	assert msg == "negative";
}

function drainOnFailure(items: string[], n: int32): string[] {
	const removed: string[] = [];
	const run = (): void => {
		try {
			raiseAbove(n, 1);
		} catch (error) {
			for (let i = items.length - 1; i >= 0; i -= 1) {
				removed.push(items[i]);
			}
		}
	};
	run();
	return removed;
}

test "a counted loop in a catch reached only by a call's raise runs" {
	assert drainOnFailure(["a", "b"], 1).length == 0;
	assert drainOnFailure(["a", "b"], 2).join(",") == "b,a";
}

interface Adopted<T> {
	value: T;
	disposed: boolean;
}

interface Point {
	x: int32;
}

function adoptAll<T>(values: T[], limit: int32): Adopted<T>[] {
	const created: Adopted<T>[] = [];
	try {
		let n: int32 = 0;
		for (const value of values) {
			n += 1;
			created.push({ value: value, disposed: false });
			raiseAbove(n, limit);
		}
	} catch (error) {
		for (const child of created) { child.disposed = true; }
	}
	return created;
}

test "a for-of loop in the catch of a generic routine runs per instance" {
	const words = adoptAll<string>(["a", "b", "c"], 1);
	assert words.length == 2 && words[0].disposed && words[1].disposed;
	const points = adoptAll<Point>([{ x: 1 }], 1);
	assert points.length == 1 && !points[0].disposed && points[0].value.x == 1;
}
