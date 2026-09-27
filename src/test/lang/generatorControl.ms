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
