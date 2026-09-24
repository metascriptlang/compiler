// @stdout: 12 10 30 11 6

// A named function passed where a function-typed parameter is declared becomes a closure pair
// at the call: into a free function, beside a capturing lambda, into a generic parameter, and
// through an extension call.
function applyTo(f: (x: number) => number, v: number): number { return f(v); }
function twice(f: (x: number) => number, g: (x: number) => number): number { return g(f(1)); }
function applyG<T>(f: (x: T) => T, v: T): T { return f(v); }
function viaExt(this n: number, f: (x: number) => number): number { return f(n); }

function dbl(x: number): number { return x * 2; }
function inc(x: number): number { return x + 1; }

export function main(): void {
	const k = 8;
	const a = applyTo(dbl, 6);
	const b = twice(dbl, (x: number): number => x + k);
	const c = applyG(dbl, 15);
	const d = applyG(inc, 10);
	const e = (3 as number).viaExt(dbl);
	console.log(`${a} ${b} ${c} ${d} ${e}`);
}

main();
