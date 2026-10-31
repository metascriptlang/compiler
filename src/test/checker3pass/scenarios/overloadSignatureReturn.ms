import { checkOnly } from "../helpers";

test "an overload signature's return must be held by the implementation's, for functions and methods" {
	const errors = checkOnly(`
function f(s: string): boolean;
function f(s: number): string;
function f(s: string | number): number | string { return 1; }
class K {
	m(s: string): boolean;
	m(s: number): string;
	m(s: string | number): number | string { return 1; }
}
const a = f("x");
const b = new K().m("x");
`).errors;
	const text = errors.join("\n");
	assert text.contains("Overload signature for 'f' has return type 'boolean' incompatible with implementation return type 'number | string'"), "function: " + text;
	assert text.contains("Overload signature for 'm' has return type 'boolean' incompatible with implementation return type 'number | string'") && errors.length == 2, "method: " + text;
	assert !text.contains("K_m"), "mangled name: " + text;
}

test "a call takes the chosen signature's return type, for functions and methods" {
	const errors = checkOnly(`
function parse(s: string): number;
function parse(s: number): string;
function parse(s: string | number): number | string { return typeof s == "string" ? s.length : "x"; }
class Reader {
	read(s: string): number;
	read(s: number): string;
	read(s: string | number): number | string { return typeof s == "string" ? s.length : "x"; }
}
const n: number = parse("a");
const t: string = parse(4);
const rn: number = new Reader().read("a");
const rt: string = new Reader().read(4);
const bad: string = parse("a");
`).errors;
	assert errors.length == 1, errors.join("\n");
}

test "a signature return wider than the implementation's, or void, is compatible; unassignable both ways is refused" {
	const errors = checkOnly(`
function w(s: string): number | string;
function w(s: number): number | string;
function w(s: string | number): number { return 1; }
function v(s: string): void;
function v(s: number): void;
function v(s: string | number): number { return 1; }
class K {
	m(s: string): number | string | boolean;
	m(s: number): number | string | boolean;
	m(s: string | number): number | string { return 1; }
}
const a: number | string = w("x");
v("x");
const b: number | string | boolean = new K().m(1);
function bad(s: string): boolean;
function bad(s: number): boolean;
function bad(s: string | number): number { return 1; }
const c = bad("x");
`).errors;
	assert errors.length == 1 && errors[0].contains("Overload signature for 'bad' has return type 'boolean' incompatible with implementation return type 'number'"), errors.join("\n");
}

test "a signature may omit the implementation's defaulted parameters, never a required one, and never adds one" {
	const errors = checkOnly(`
function f(a: string): number;
function f(a: string, n: int32 = 1): number { return a.length + n; }
class K {
	m(a: string): number;
	m(a: string, n: int32 = 2): number { return a.length + n; }
}
const x = f("ab");
const y = new K().m("ab");
function short(a: string): number;
function short(a: string, n: int32): number { return n; }
function long(a: string, n: int32, z: int32): number;
function long(a: string, n: int32 = 1): number { return n; }
const s = short("a");
const l = long("a", 1, 2);
class M {
	cut(a: string): number;
	cut(a: string, n: int32): number { return n; }
}
const c = new M().cut("a");
`).errors;
	const text = errors.join("\n");
	assert text.contains("Overload signature for 'short' has 1 parameter(s) but implementation requires 2"), text;
	assert text.contains("Overload signature for 'long' has 3 parameter(s) but implementation has 2"), text;
	assert text.contains("Overload signature for 'cut' has 1 parameter(s) but implementation requires 2"), text;
	assert !text.contains("'f'") && !text.contains("'m'"), text;
}

function errorLines(source: string, text: string): int32[] {
	const lines: int32[] = [];
	for (const e of checkOnly(source).ctx.errors) {
		if (e.message.contains(text)) lines.push(e.line);
	}
	return lines;
}

test "a signature set no call reaches is checked at the signature, for functions, methods and constructors" {
	const source = `
function f(a: string): string;
function f(a: number, b: number, c: number): string;
function f(a: string | number): string { return "x"; }
class K {
	m(a: boolean): number;
	m(a: number): number { return a; }
}
class C {
	constructor(a: boolean);
	constructor(a: number) {}
}
`;
	assert errorLines(source, "Overload signature for 'f' has 2 parameter(s)").length == 0;
	assert errorLines(source, "Overload signature for 'f' has 3 parameter(s) but implementation has 1").join(",") == "3";
	assert errorLines(source, "Overload signature for 'm' param 1 type 'boolean'").join(",") == "6";
	assert errorLines(source, "Overload signature for 'constructor' param 1 type 'boolean'").join(",") == "10";
}

test "a call through a refused set reports nothing more, and the error stays on the signature" {
	const source = `
function f(a: string): string;
function f(a: number, b: number, c: number): string;
function f(a: string | number): string { return "x"; }
const s = f("x");
const t = f("y");
`;
	const errors = checkOnly(source).errors;
	assert errors.length == 1 && errorLines(source, "Overload signature for 'f'").join(",") == "3", errors.join("\n");
}

test "a signature set without an implementation is refused at its last signature, whether or not a call reaches it" {
	const source = `
function g(a: string): string;
function g(a: number): string;
class E {
	m(a: string): void;
}
function h(a: string): string;
const r = h("x");
`;
	assert errorLines(source, "Overloaded function 'g' has no implementation").join(",") == "3";
	assert errorLines(source, "Overloaded function 'm' has no implementation").join(",") == "5";
	assert errorLines(source, "Overloaded function 'h' has no implementation").join(",") == "7";
}

test "a signature set with a second implementation is refused there, for functions and methods" {
	const source = `
function d(a: string): string;
function d(a: string): string { return a; }
function d(a: string): string { return a + "!"; }
class K {
	m(a: string): string;
	m(a: string): string { return a; }
	m(a: string): string { return a + "?"; }
}
function two(a: string): string { return a; }
function two(a: number): string { return "n"; }
`;
	assert errorLines(source, "Overloaded function 'd' has more than one implementation").join(",") == "4";
	assert errorLines(source, "Overloaded function 'm' has more than one implementation").join(",") == "8";
	assert errorLines(source, "'two'").length == 0;
}

test "a written empty method body implements its signatures; an abstract member stays body-less" {
	const source = `
class Quiet {
	ping(a: string): void;
	ping(a: string | int32): void {}
}
abstract class Shape {
	abstract area(): number;
}
new Quiet().ping("x");
`;
	const errors = checkOnly(source).errors;
	assert errors.length == 0, errors.join("\n");
}

test "the declarations of a set agree with the implementation on export, staticness and visibility" {
	const source = `
export function e(a: string): string;
function e(a: string | number): string { return "e"; }
class V {
	private m(a: string): string;
	m(a: string | number): string { return "m"; }
	static s(a: string): string;
	s(a: string | number): string { return "s"; }
	protected p(a: string): string;
	protected p(a: string | number): string { return "p"; }
}
export function ok(a: string): string;
export function ok(a: string | number): string { return "ok"; }
`;
	assert errorLines(source, "Overload signatures of 'e' must all be exported or non-exported").join(",") == "2";
	assert errorLines(source, "Overload signatures of 'm' must all be public, private or protected").join(",") == "5";
	assert errorLines(source, "Overload signatures of 's' must all be static or non-static").join(",") == "7";
	assert checkOnly(source).errors.length == 3, checkOnly(source).errors.join("\n");
}

test "an extern class member declares its return type without a body" {
	const errors = checkOnly(`
extern class Host {
	read(): int32;
}
`).errors;
	assert errors.length == 0, errors.join("\n");
}
