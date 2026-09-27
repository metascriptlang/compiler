// @xfail(raiser): the Raiser VM cannot compile a yield expression ('cannot compile node kind YieldExpr')
let trace: string = "";

function* returns(n: int32): Iterator<int32> {
	yield 1;
	if (n > 0) return;
	let i: int32 = 2;
	while (true) {
		yield i;
		i++;
		if (i == 4) return;
	}
}

function* forOfLocals(xs: string[], ns: int32[]): Iterator<string> {
	for (const x of xs) {
		for (const n of ns) {
			yield x + n.toString();
		}
	}
}

function* sameNames(flag: boolean): Iterator<string> {
	if (flag) {
		const x: string = "str";
		yield x;
	} else {
		const x: int32 = 42;
		yield x.toString();
	}
	let j: int32 = 0;
	while (j < 2) {
		const x: int32 = j * 10;
		yield x.toString();
		j++;
	}
}

function* jumpsThroughFinally(): Iterator<int32> {
	let i: int32 = 0;
	while (i < 4) {
		try {
			yield i;
			if (i == 0) {
				i++;
				continue;
			}
			if (i == 2) break;
		} finally {
			trace = trace + "f" + i.toString() + ";";
		}
		i++;
	}
	yield 100;
}

function* statementKinds(k: int32): Iterator<string> {
	let i: int32 = 0;
	do {
		yield "do" + i.toString();
		i++;
	} while (i < 2);
	switch (k) {
		case 1:
			yield "case1";
			break;
		default:
			yield "default";
	}
	match (k) {
		1 => { yield "arm1"; },
		_ => { yield "wild"; },
	}
	try {
		yield "try";
	} finally {
		yield "finally";
	}
}

function collectInts(label: string, it: Iterator<int32>, expected: string): void {
	let out: string = "";
	for (const v of it) out = out + v.toString() + ",";
	if (out != expected) throw new Error(label + ": " + out);
	console.log(label + ": " + out);
}

function collectStrings(label: string, it: Iterator<string>, expected: string): void {
	let out: string = "";
	for (const v of it) out = out + v + ",";
	if (out != expected) throw new Error(label + ": " + out);
	console.log(label + ": " + out);
}

collectInts("returns(1)", returns(1), "1,");
collectInts("returns(0)", returns(0), "1,2,3,");
collectStrings("forOfLocals", forOfLocals(["a", "b"], [1, 2]), "a1,a2,b1,b2,");
collectStrings("sameNames(true)", sameNames(true), "str,0,10,");
collectStrings("sameNames(false)", sameNames(false), "42,0,10,");
collectInts("jumpsThroughFinally", jumpsThroughFinally(), "0,1,2,100,");
if (trace != "f1;f1;f2;") throw new Error("trace: " + trace);
console.log("trace: " + trace);
collectStrings("statementKinds(1)", statementKinds(1), "do0,do1,case1,arm1,try,finally,");
collectStrings("statementKinds(2)", statementKinds(2), "do0,do1,default,wild,try,finally,");
