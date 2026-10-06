// @stdout: 3 55 2.5 abb 6 2 3
// note: a function or method without a return annotation that calls itself after a return has typed it keeps that type when every later return agrees: int, float, string, a method through `this`, and a call whose value is discarded. Same output on C, JS and the Raiser.
function count(n: number) {
	if (n <= 0) return 0;
	return count(n - 1) + 1;
}

function fib(n: number) {
	if (n < 2) return n;
	return fib(n - 1) + fib(n - 2);
}

function halves(n: number) {
	if (n <= 0) return 0.5;
	return halves(n - 1) + 0.5;
}

function letters(n: number) {
	if (n <= 0) return "a";
	return letters(n - 1) + "b";
}

class Tally {
	sum(n: int32) {
		if (n <= 0) return 0;
		return this.sum(n - 1) + n;
	}
}

let visits = 0;
function walk(n: number) {
	visits += 1;
	if (n > 0) walk(n - 1);
	return n;
}

function main(): void {
	const w = walk(2);
	console.log(`${count(3)} ${fib(10)} ${halves(4)} ${letters(2)} ${new Tally().sum(3)} ${w} ${visits}`);
}

main();
