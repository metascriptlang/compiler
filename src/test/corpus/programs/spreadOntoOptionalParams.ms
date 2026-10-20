// @stdout: one-short=1 2|
// @stdout: one-empty=1 null|
// @stdout: opt-empty=1 null null|
// @stdout: opt-short=1 2 null|
// @stdout: opt-exact=1 2 3|
// @stdout: opt-long=1 2 3|
// @stdout: once=1 5 6 calls=1|
// @stdout: default-short=1 2 9|
// @stdout: default-exact=1 2 3|
// @stdout: strings=a x z|
// @stdout: strings-long=a p q|
// @stdout: boxes=1 2 -1|
// @stdout: method=hi x !|
// @stdout: tuple-required=5|
// @stdout: tuple-optional=1 2 3|
// @stdout: tuple-mixed=k4|
// @stdout: tuple-new=2x tuple-rest=7|
// @stdout: generic=1 2 null|a y z|1 null null|
// @stdout: overload=n 1 2|s x y z|n 1 null|
// @stdout: method-overload=n 1 2|
// @stdout: ctor=1 y z|1 null d|
// @stdout: rest=1 null []|1 2 []|1 5 [6,7,8]|calls=2|
// @stdout: loop=< null z;< a z;< b c;< d e;|
// note: a spread argument that lands only on optional parameters fills each one from the array in order, evaluates the array once, leaves a missing element to the parameter's absent value or default and drops the elements past the last parameter; a tuple spread expands into one argument per element, so it can also fill required parameters. Same output on every lane.
function one(a: number, b?: number): string { return `${a} ${b}`; }
function opt(a: number, b?: number, c?: number): string { return `${a} ${b} ${c}`; }
function dflt(a: number, b?: number, c: number = 9): string { return `${a} ${b} ${c}`; }
function names(a: string, b?: string, c: string = "z"): string { return `${a} ${b} ${c}`; }
function two(a: number, b: number): number { return a + b; }
function sn(s: string, n: number): string { return `${s}${n}`; }

class Box {
	v: number;
	constructor(v: number) { this.v = v; }
}

function boxes(a: Box, b?: Box, c?: Box): string {
	return `${a.v} ${b != null ? b.v : -1} ${c != null ? c.v : -1}`;
}

class Pair {
	s: string;
	constructor(a: number, b: string) { this.s = `${a}${b}`; }
}

function sumRest(first: number, ...rest: number[]): number {
	let total = first;
	for (const r of rest) total += r;
	return total;
}

function gen<T>(a: T, b?: T, c?: T): string { return `${a} ${b} ${c}`; }

function ov(a: number, b?: number): string { return `n ${a} ${b}`; }
function ov(a: string, b?: string, c?: string): string { return `s ${a} ${b} ${c}`; }

class Hi {
	hi(a: number, b?: number): string { return `n ${a} ${b}`; }
	hi(a: string, b?: string): string { return `s ${a} ${b}`; }
}

class Made {
	s: string;
	constructor(a: number, b?: string, c: string = "d") { this.s = `${a} ${b} ${c}`; }
}

function optRest(a: number, b?: number, ...rest: number[]): string {
	return `${a} ${b} [${rest.join(",")}]`;
}

class Greeter {
	greet(a: string, b?: string, c: string = "!"): string { return `${a} ${b} ${c}`; }
}

let calls = 0;
function make(): number[] {
	calls += 1;
	return [5, 6, 7, 8];
}

function inLoop(rows: string[][]): string {
	let out = "";
	for (const row of rows) out += names("<", ...row) + ";";
	return out;
}

function main(): void {
	const empty: number[] = [];
	const short: number[] = [2];
	const exact: number[] = [2, 3];
	const long: number[] = [2, 3, 4, 5];
	console.log(`one-short=${one(1, ...short)}|`);
	console.log(`one-empty=${one(1, ...empty)}|`);
	console.log(`opt-empty=${opt(1, ...empty)}|`);
	console.log(`opt-short=${opt(1, ...short)}|`);
	console.log(`opt-exact=${opt(1, ...exact)}|`);
	console.log(`opt-long=${opt(1, ...long)}|`);
	const once = opt(1, ...make());
	console.log(`once=${once} calls=${calls}|`);
	console.log(`default-short=${dflt(1, ...short)}|`);
	console.log(`default-exact=${dflt(1, ...exact)}|`);
	const strs: string[] = ["x"];
	const more: string[] = ["p", "q", "r"];
	console.log(`strings=${names("a", ...strs)}|`);
	console.log(`strings-long=${names("a", ...more)}|`);
	const bs: Box[] = [new Box(2)];
	console.log(`boxes=${boxes(new Box(1), ...bs)}|`);
	const g = new Greeter();
	console.log(`method=${g.greet("hi", ...strs)}|`);
	const t: [number, number] = [2, 3];
	const ts: [string, number] = ["k", 4];
	console.log(`tuple-required=${two(...t)}|`);
	console.log(`tuple-optional=${opt(1, ...t)}|`);
	console.log(`tuple-mixed=${sn(...ts)}|`);
	const ps: [number, string] = [2, "x"];
	const ns: [number, number] = [3, 4];
	console.log(`tuple-new=${new Pair(...ps).s} tuple-rest=${sumRest(...ns)}|`);
	const yz: string[] = ["y", "z", "w"];
	const none: string[] = [];
	console.log(`generic=${gen(1, ...short)}|${gen("a", ...yz)}|${gen(1, ...empty)}|`);
	console.log(`overload=${ov(1, ...short)}|${ov("x", ...yz)}|${ov(1, ...empty)}|`);
	const hi = new Hi();
	console.log(`method-overload=${hi.hi(1, ...short)}|`);
	console.log(`ctor=${new Made(1, ...yz).s}|${new Made(1, ...none).s}|`);
	console.log(`rest=${optRest(1, ...empty)}|${optRest(1, ...short)}|${optRest(1, ...make())}|calls=${calls}|`);
	console.log(`loop=${inLoop([[], ["a"], ["b", "c"], ["d", "e", "f"]])}|`);
}

main();
