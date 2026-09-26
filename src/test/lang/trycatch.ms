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
