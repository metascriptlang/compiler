// Language tests: try/catch/finally + throw

function mayThrow(x: number): number {
	if (x < 0) throw "negative";
	return x * 2;
}

test "basic try/catch — no throw" {
	let r = 0;
	try {
		r = mayThrow(5);
	} catch (e) {
		r = -1;
	}
	assert r === 10;
}

test "basic try/catch — throws" {
	let r = 0;
	try {
		r = mayThrow(-1);
	} catch (e) {
		r = -1;
	}
	assert r === -1;
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
	assert log === "try,finally";
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
	assert log === "try,catch,finally";
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
	assert inner === "inner-caught";
	assert outer === "outer-try";
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
	assert caught === "got-it";
}
