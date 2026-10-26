// @stdout: 3 10 10 20 7
// note: a closure literal passed as a call argument is a temporary pair the call borrows and releases afterwards: two literals to one function, a literal capturing a mutable local, a literal called through a closure parameter, and literals passed to a closure call.
function both(a: () => number, b: () => number): number { return a() + b(); }
function apply(f: (x: number) => number, x: number): number { return f(x); }
function viaLocal(): number {
	let n = 3;
	n += 1;
	return both((): number => n, (): number => n + 1) + apply((x: number): number => x + n, 1);
}
function nested(): number {
	let n = 10;
	n += 0;
	const twice = (g: () => number): number => g() + g();
	return twice((): number => n);
}
function closureCall(): number {
	let n = 5;
	n += 0;
	const run = (g: () => number, h: () => number): number => g() + h();
	return run((): number => n, (): number => n + 2);
}
console.log(both((): number => 1, (): number => 2), viaLocal() - 4, nested() / 2, nested(), closureCall() - 10 + 5);
