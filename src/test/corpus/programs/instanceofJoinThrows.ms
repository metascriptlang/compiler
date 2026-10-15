// @stdout: instanceof-join ok 9
// note: after an `instanceof` test on an `Error | null` local, the branches join back to `Error | null` the way TS does: a subclass the test brought in folds into its base class at the join, and the false branch of `instanceof` keeps every member that is not an instance of the tested class, `null` included. So `throw x` throws the base-class value and a later `x !== null` test still runs. One class and two classes in the test, `throw` at the top of a branch and inside a nested loop. Same output on C, JS and the Raiser.
let wrong = "";
let rows = 0;
function row(name: string, got: string, want: string): void {
	rows += 1;
	if (got != want) wrong += " " + name + "=" + got + "(want " + want + ")";
}

class Mine extends Error {
	n: int32;
	constructor(n: int32) { super("mine"); this.n = n; }
}

class Other extends Error {
	constructor() { super("other"); }
}

function mayFail(n: int32): void {
	if (n == 1) { throw new Error("boom"); }
	if (n == 2) { throw new Mine(2); }
	if (n == 3) { throw new Other(); }
}

let halted = "";
function halt(e: Error): void { halted += e.message; }

function run(n: int32): int32 {
	let result: int32 = 0;
	let thrown: Error | null = null;
	try {
		mayFail(n);
	} catch (e) {
		thrown = e;
	} finally {
		result = 1;
	}
	if (thrown !== null) {
		if (!(thrown instanceof Mine)) {
			result = 2;
		}
	}
	if (thrown !== null && result > 0) {
		halt(thrown);
		throw thrown;
	}
	return result;
}

function nested(n: int32): string {
	let thrown: Error | null = null;
	try {
		mayFail(n);
	} catch (e) {
		thrown = e;
	}
	let kind = "base";
	if (thrown instanceof Mine) {
		kind = "mine";
	} else if (thrown instanceof Other) {
		kind = "other";
	}
	if (thrown !== null) {
		for (let i = 0; i < 1; i += 1) {
			if (kind !== "") {
				throw thrown;
			}
		}
	}
	return kind;
}

function attempt(f: (n: int32) => string, n: int32): string {
	try {
		return f(n);
	} catch (e) {
		return "caught " + (e as Error).message;
	}
}

const runText = (n: int32): string => run(n).toString();
row("run none", attempt(runText, 0), "1");
row("run base", attempt(runText, 1), "caught boom");
row("run mine", attempt(runText, 2), "caught mine");
row("run other", attempt(runText, 3), "caught other");
row("halted", halted, "boommineother");
row("nested none", attempt(nested, 0), "base");
row("nested base", attempt(nested, 1), "caught boom");
row("nested mine", attempt(nested, 2), "caught mine");
row("nested other", attempt(nested, 3), "caught other");
console.log(wrong == "" ? "instanceof-join ok " + rows.toString() : "instanceof-join WRONG" + wrong);
