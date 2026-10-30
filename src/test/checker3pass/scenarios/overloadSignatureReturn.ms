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
