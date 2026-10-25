// @stdout: ternary: true log=
// @stdout: and: false log=
// @stdout: nested: true log=
// @stdout: nested else: false log=
// @stdout: taken: true log=sF
// @stdout: literal: 3 log=abc
// @stdout: first: 2 log=ab
// @stdout: call: 3 log=ab
// @stdout: strings: xxy log=ab
// @stdout: nested call: 4 log=abc
let log = "";
function side(tag: string, v: int32): int32 { log = log + tag; return v; }
function pairs(tag: string): int32[] { log = log + tag; return [7, 8]; }
function names(tag: string): string[] { log = log + tag; return ["x", "y"]; }
function f0(a: uint8, ...rest: int32[]): boolean { log = log + "F"; return rest.length > 1; }
function count(p0: int32, ...rest: int32[]): int32 { return p0 + rest.length; }
function joined(head: string, ...rest: string[]): string { return head + rest.join(""); }
function ternary(c: boolean): boolean { return c ? f0(1, ...[2, side("s", 1)]) : true; }
function andRhs(c: boolean): boolean { return c && f0(1, ...[2, side("s", 1)]); }
function nestedElse(c: boolean, d: boolean): boolean { return c ? true : d ? false : f0(1, ...[side("s", 1)]); }
function run(): void {
	log = "";
	const a = ternary(false);
	console.log("ternary: " + String(a) + " log=" + log);
	log = "";
	const b = andRhs(false);
	console.log("and: " + String(b) + " log=" + log);
	log = "";
	const c = nestedElse(true, false);
	console.log("nested: " + String(c) + " log=" + log);
	log = "";
	const c2 = nestedElse(false, true);
	console.log("nested else: " + String(c2) + " log=" + log);
	log = "";
	const d = ternary(true);
	console.log("taken: " + String(d) + " log=" + log);
	log = "";
	const e = count(side("a", 1), ...[side("b", 2), side("c", 3)]);
	console.log("literal: " + e.toString() + " log=" + log);
	log = "";
	const e2 = count(...[side("a", 1)], side("b", 2));
	console.log("first: " + e2.toString() + " log=" + log);
	log = "";
	const f = count(side("a", 1), ...pairs("b"));
	console.log("call: " + f.toString() + " log=" + log);
	log = "";
	const g = joined(names("a")[0], ...names("b"));
	console.log("strings: " + g + " log=" + log);
	log = "";
	const h = count(count(side("a", 1), ...pairs("b")), ...[side("c", 3)]);
	console.log("nested call: " + h.toString() + " log=" + log);
}
run();
