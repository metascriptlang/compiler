// @stdout: rest only: 6
// @stdout: covers first: 10
// @stdout: first then more: 6
// @stdout: one element: 5
// @stdout: strings: h:a,b
// @stdout: nested: 6
// @stdout: method: 106
// @stdout: fixed only: 12
// @stdout: nested literal: 34
// @stdout: constructor: 702
function sumRest(first: int32, ...rest: int32[]): int32 { let s = first; for (const r of rest) s += r; return s; }
function label(head: string, ...rest: string[]): string { return head + ":" + rest.join(","); }
function two(a: int32, b: int32): int32 { return a * 10 + b; }
class P {
	v: int32;
	constructor(a: int32, ...r: int32[]) { this.v = a * 100 + r.length; }
}
class Acc {
	base: int32 = 100;
	add(first: int32, ...rest: int32[]): int32 { let s = this.base + first; for (const r of rest) s += r; return s; }
}
function run(): void {
	console.log("rest only: " + sumRest(1, ...[2, 3]).toString());
	console.log("covers first: " + sumRest(...[1, 2, 3, 4]).toString());
	console.log("first then more: " + sumRest(...[1, 2], 3).toString());
	console.log("one element: " + sumRest(...[5]).toString());
	console.log("strings: " + label(...["h", "a", "b"]));
	console.log("nested: " + sumRest(...[sumRest(...[1, 2]), 3]).toString());
	console.log("method: " + new Acc().add(...[1, 2, 3]).toString());
	console.log("fixed only: " + two(...[1, 2]).toString());
	console.log("nested literal: " + two(...[3, ...[4]]).toString());
	console.log("constructor: " + new P(...[7, 8, 9]).v.toString());
}
run();
