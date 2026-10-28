// @stdout: close caught fin threw
// @stdout: argument caught arg
// @stdout: callee caught 5
// note: the function value a call holds for its callee is released when the call raises, as when it returns: a generator closed early whose finally raises, a closure whose argument raises, and a closure that raises after an argument that runs code.
function* failingFinally(): Iterator<int32> {
	try {
		yield 1;
	} finally {
		throw new Error("fin threw");
	}
}

function closeRaises(): string {
	try {
		for (const x of failingFinally()) {
			break;
		}
	} catch (e) {
		return "caught " + (e as Error).message;
	}
	return "none";
}

function arg(): number {
	throw new Error("arg");
}

function twice(n: number): number {
	return n * 2;
}

function argumentRaises(): string {
	const base: number = 3;
	const f = (x: number): number => x + base;
	try {
		return `${f(arg())}`;
	} catch (e) {
		return "caught " + (e as Error).message;
	}
}

function calleeRaises(): string {
	const limit: number = 4;
	const f = (x: number): number => { if (x > limit) throw new Error(`${x}`); return x; };
	try {
		return `${f(twice(2) + 1)}`;
	} catch (e) {
		return "caught " + (e as Error).message;
	}
}

console.log(`close ${closeRaises()}`);
console.log(`argument ${argumentRaises()}`);
console.log(`callee ${calleeRaises()}`);
