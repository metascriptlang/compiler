// @stdout: named caught big
// @stdout: captured caught stop after 9
// @stdout: method caught odd 3
// @stdout: later argument caught late
// note: a function passed to a call that raises is released on the way out, as it is when the call returns: a named function, a closure that captures, a closure handed to a method of the std, and a closure whose call never starts because a later argument raises.
function thrower(n: number): number {
	if (n > 5) throw new Error("big");
	return n;
}

function callback(f: (x: number) => number): number {
	return f(9);
}

function late(): number {
	throw new Error("late");
}

function both(f: (x: number) => number, n: number): number {
	return f(n);
}

function named(): string {
	try { return `${callback(thrower)}`; } catch (e) { return `caught ${(e as Error).message}`; }
}

function captured(): string {
	let calls: number = 0;
	try {
		return `${callback((x: number): number => { calls = calls + x; if (calls > 0) throw new Error("stop"); return calls; })}`;
	} catch (e) {
		return `caught ${(e as Error).message} after ${calls}`;
	}
}

function method(): string {
	const xs: number[] = [4, 3, 2, 1];
	let seen: number = 0;
	try {
		xs.sort((a: number, b: number): number => { seen = seen + 1; if (seen == 3) throw new Error("odd"); return a - b; });
		return "sorted";
	} catch (e) {
		return `caught ${(e as Error).message} ${seen}`;
	}
}

function laterArgument(): string {
	const k = 2;
	try { return `${both((x: number): number => x + k, late())}`; } catch (e) { return `caught ${(e as Error).message}`; }
}

console.log(`named ${named()}`);
console.log(`captured ${captured()}`);
console.log(`method ${method()}`);
console.log(`later argument ${laterArgument()}`);
