let trace = "";

function* retInLoop(): Iterator<int32> {
	try {
		for (let i = 0; i < 3; i += 1) {
			yield i;
			if (i == 1) return;
		}
	} finally {
		trace += "fin;";
		throw new Error("loopfin");
	}
}

function* breakOut(): Iterator<int32> {
	while (true) {
		try {
			yield 1;
			break;
		} finally {
			trace += "bfin;";
			throw new Error("breakfin");
		}
	}
	trace += "unreached;";
}

function* caughtInside(): Iterator<int32> {
	try {
		try {
			yield 1;
			return;
		} finally {
			trace += "inner;";
			throw new Error("inner");
		}
	} catch (e) {
		trace += "caught " + (e as Error).message + ";";
	}
	yield 2;
}

function* twoFinallies(): Iterator<int32> {
	try {
		try {
			yield 1;
			return;
		} finally {
			trace += "in;";
			throw new Error("in");
		}
	} finally {
		trace += "out;";
	}
}

function* cLoopReturn(): Iterator<int32> {
	try {
		yield 1;
		for (let i = 0; i < 5; i += 1) {
			if (i == 2) return;
		}
	} finally {
		trace += "cfin;";
	}
}

function drain(it: Iterator<int32>): void {
	try {
		for (const x of it) trace += x.toString() + ",";
	} catch (e) {
		trace += "out " + (e as Error).message + ";";
	}
}

async function tick(): Promise<int32> {
	return 1;
}

async function asyncBreakOut(): Promise<void> {
	while (true) {
		try {
			await tick();
			break;
		} finally {
			trace += "afin;";
			throw new Error("afin");
		}
	}
	trace += "unreached;";
}

async function main(): Promise<void> {
	drain(retInLoop());
	drain(breakOut());
	drain(caughtInside());
	drain(twoFinallies());
	drain(cLoopReturn());
	try {
		await asyncBreakOut();
	} catch (e) {
		trace += "out " + (e as Error).message + ";";
	}
	const expected = "0,1,fin;out loopfin;1,bfin;out breakfin;1,inner;caught inner;2,1,in;out;out in;1,cfin;afin;out afin;";
	console.log(trace);
	if (trace != expected) throw new Error("trace differs from TS: " + expected);
}

main();
