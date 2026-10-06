// @stdout: 3 | false 012eoeo | 6
// note: adjacent local function declarations see each other, so they can call each other however they are ordered; a local function without a return annotation returns what its body returns, and one that only recurses on itself infers void. Same output on C, JS and the Raiser.
function counter(): () => number {
	let n = 0;
	function a(): number {
		n += 1;
		return n < 3 ? b() : n;
	}
	function b(): number { return a(); }
	return a;
}

function parity(): string {
	let log = "";
	function even(n: int32): boolean { log += "e"; return n == 0 ? true : odd(n - 1); }
	function odd(n: int32): boolean { log += "o"; return n == 0 ? false : even(n - 1); }
	function walk(n: int32) { if (n > 0) walk(n - 1); log += String(n); }
	walk(2);
	return String(even(3)) + " " + log;
}

function inferred() {
	function inner() { return 5; }
	return inner() + 1;
}

console.log(`${counter()()} | ${parity()} | ${inferred()}`);
