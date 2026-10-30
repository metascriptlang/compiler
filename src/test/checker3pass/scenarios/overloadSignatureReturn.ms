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
	assert text.contains("has return type 'boolean' incompatible with implementation return type 'number | string'") && errors.length == 2, "method: " + text;
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
