function* bareReturn(): Iterator<int32> { yield 1; return; }

function* branchReturn(stop: boolean): Iterator<int32> { yield 1; if (stop) return; yield 2; }

function* loopReturn(): Iterator<int32> {
	let value: int32 = 0;
	while (true) { yield value; value++; if (value == 3) return; }
}

let finallyTrace = "";

function* finalizingReturn(stop: boolean): Iterator<int32> {
	try { yield 1; if (stop) return; yield 2; }
	finally { finallyTrace += "fin;"; }
	yield 3;
}

function collectIterator(values: Iterator<int32>): string {
	let text = "";
	for (const value of values) text += value.toString();
	return text;
}

test "generatorControl: generator return terminates iteration at bare branch and loop depths" {
	assert collectIterator(bareReturn()) == "1";
	assert collectIterator(branchReturn(true)) == "1";
	assert collectIterator(branchReturn(false)) == "12";
	assert collectIterator(loopReturn()) == "012";
}

test "generatorControl: generator return and normal completion each execute split finally exactly once" {
	finallyTrace = "";
	assert collectIterator(finalizingReturn(true)) == "1";
	assert finallyTrace == "fin;";
	assert collectIterator(finalizingReturn(false)) == "123";
	assert finallyTrace == "fin;fin;";
}

function firstAbove(limit: int32): int32 {
	for (const value of finalizingReturn(false)) {
		if (value > limit) return value;
	}
	return -1;
}

test "generatorControl: leaving a for..of early by break, return or throw runs the generator's finally once" {
	finallyTrace = "";
	for (const value of finalizingReturn(false)) {
		if (value == 1) break;
	}
	assert finallyTrace == "fin;";
	assert firstAbove(1) == 2;
	assert finallyTrace == "fin;fin;";
	try {
		for (const value of finalizingReturn(false)) {
			if (value == 2) throw new Error("left");
		}
	} catch (e) {
		finallyTrace += "caught;";
	}
	assert finallyTrace == "fin;fin;fin;caught;";
}

function* throwingFinally(stop: boolean): Iterator<int32> {
	try { yield 1; if (stop) return; yield 2; }
	finally { finallyTrace += "fin;"; throw new Error("fin"); }
}

test "generatorControl: a return crossing a finally that throws runs that finally once and raises its error" {
	for (const stop of [true, false]) {
		finallyTrace = "";
		let caught = "";
		try {
			collectIterator(throwingFinally(stop));
		} catch (e) {
			caught = (e as Error).message;
		}
		assert finallyTrace == "fin;";
		assert caught == "fin";
	}
}
