// @stdout: 6 9 6 12 -1
// @xfail(raiser): raiser runtime error "expected an object, got value kind Int" when a method calls a function value it received; same on a control built from origin/main

// A function value passed to a method parameter takes the closure representation the
// parameter declares, for a bare function type and for a nullable one, whether the value is
// a named function or a lambda.
class K {
	run(f: (x: number) => number): number { return f(3); }
	runOpt(f: ((x: number) => number) | null): number { return f != null ? f(3) : -1; }
}

function dbl(x: number): number { return x * 2; }

export function main(): void {
	const k = new K();
	const a = k.run(dbl);
	const b = k.run((x: number): number => x * 3);
	const c = k.runOpt(dbl);
	const d = k.runOpt((x: number): number => x * 4);
	const e = k.runOpt(null);
	console.log(`${a} ${b} ${c} ${d} ${e}`);
}

main();
