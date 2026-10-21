import { checkOnly } from "../helpers";

const SHAPES = `
type Circle = { kind: "c"; r: number };
type Square = { kind: "s"; side: number };
type Shape = Circle | Square;
type Loose = { kind: string; r: number };
type Radius = { r: number };
function area(s: Shape): number { return 1; }
`;

test "a written field a later spread gives is refused at the written key" {
	const text = checkOnly(SHAPES + `
interface P { a: number; b: string }
const c: Circle = { kind: "c", r: 2 };
const x: P = { a: 1, b: "s" };
const y: Radius = { r: 2 };
const first = { a: 0, ...x, b: "s9" };
const twice = { a: 0, ...y, ...x };
const picked = area({ kind: "s", ...c });
`).errors.join("\n");
	assert text.contains("'a' is specified more than once, so this usage will be overwritten: the spread after it gives 'a'"), "a written a before a spread of P is dead: " + text;
	assert text.contains("'kind' is specified more than once, so this usage will be overwritten: the spread after it gives 'kind'"), "a written discriminant before a spread that gives it is dead: " + text;
}

test "a field written after the spread or a spread that lacks it keeps the written value" {
	const errors = checkOnly(SHAPES + `
const c: Circle = { kind: "c", r: 2 };
const radius: Radius = { r: 4 };
const after = area({ ...c, kind: "c", r: 3 });
const beside = area({ kind: "c", ...radius });
`).errors;
	assert errors.length == 0, "a key after the spread, or before a spread without it, is accepted: " + errors.join("\n");
}

test "a spread discriminant that names no single member is refused" {
	const text = checkOnly(SHAPES + `
const loose: Loose = { kind: "c", r: 2 };
const s = area({ ...loose });
`).errors.join("\n");
	assert text.contains("the spread gives 'kind' as string, which names no member of the union: give 'kind' after the spread"), "a string-typed kind picks no member: " + text;
}

test "a spread field the literal's field cannot take is refused at the spread" {
	const text = checkOnly(`
interface Src { n: string; }
interface Dst { n: number; }
interface Wide { n: int64; }
interface Slim { n: int32; }
const s: Src = { n: "abc" };
const w: Wide = { n: 5000000000 as int64 };
const d: Dst = { ...s };
const m: Slim = { ...w };
`).errors.join("\n");
	assert text.contains("field 'n' from the spread does not fit the literal's 'n': Type 'string' is not assignable to type 'number'"), "a string field into a number field: " + text;
	assert text.contains("field 'n' from the spread does not fit the literal's 'n': implicit int64 → int32 conversion narrows"), "an int64 field into an int32 field: " + text;
}

test "a spread field written again after the spread is judged by the written value" {
	const errors = checkOnly(`
interface Src { n: string; t: int32; }
interface Dst { n: number; t: int32; }
const s: Src = { n: "abc", t: 1 };
const d: Dst = { ...s, n: 4 };
`).errors;
	assert errors.length == 0, "n written after the spread replaces the spread's n: " + errors.join("\n");
}

test "a field the target requires that no spread or key gives is refused" {
	const text = checkOnly(`
class Box { v: int32 = 1; }
interface Src { a: number; }
interface DstArr { a: number; items: int32[]; }
interface DstBox { a: number; box: Box; }
interface DstFn { a: number; f: (n: int32) => int32; }
const s: Src = { a: 1 };
const d: DstArr = { ...s };
const b: DstBox = { ...s };
const f: DstFn = { ...s };
`).errors.join("\n");
	assert text.contains("field 'items' must be initialized"), "an array field the spread lacks: " + text;
	assert text.contains("field 'box' must be initialized"), "a class field the spread lacks: " + text;
	assert text.contains("field 'f' must be initialized"), "a function field the spread lacks: " + text;
}

test "a required field a spread or a later key gives, or a nullable field left out, is accepted" {
	const errors = checkOnly(`
interface Src { a: number; }
interface WithItems { a: number; items: int32[]; }
interface Dst { a: number; items: int32[]; }
interface DstOpt { a: number; note: string | null; items?: int32[] | null; }
const s: Src = { a: 1 };
const w: WithItems = { a: 2, items: [1, 2] };
const given: Dst = { ...w };
const after: Dst = { ...s, items: [3] };
const opt: DstOpt = { ...s };
`).errors;
	assert errors.length == 0, "every required field is given: " + errors.join("\n");
}

test "a spread of a generic instance is judged by its instantiated fields" {
	const errors = checkOnly(`
interface G<T> { a: T | null; n: int32; }
class Box<T> { a: T | null = null; n: int32 = 1; }
interface H { a: string; n: int32; }
interface W { a: string | null; n: int32; }
const g: G<string> = { a: null, n: 1 };
const fromInterface: H = { ...g };
const fromClass: H = { ...new Box<string>() };
const fits: W = { ...g };
const free = { ...g };
const read: int32 = free.n;
`).errors;
	const text = errors.join("\n");
	assert text.split("field 'a' from the spread does not fit the literal's 'a': Type 'string | null' is not assignable to type 'string'").length == 3, "a nullable field of G<string> and Box<string> into a string field: " + text;
	assert !text.contains("Property 'n' does not exist"), "a free literal takes the instance's fields: " + text;
	assert errors.length == 2, "only the two refusals: " + text;
}

test "a spread of a runtime collection is refused and a class instance spread copies its fields" {
	const errors = checkOnly(`
class Pt { x: int32 = 1; y: string = "p"; }
interface H { x: int32; y: string; }
const m = new Map<string, int32>();
const s = new Set<int32>();
const free = { ...m };
const typed: H = { ...s, x: 1, y: "y" };
const copied: H = { ...new Pt() };
const loose = { ...new Pt() };
const read: int32 = loose.x;
`).errors;
	const text = errors.join("\n");
	assert text.contains("cannot spread a Map<string, int32> into an object literal: its contents are not fields; copy the entries with a loop"), "a Map spread: " + text;
	assert text.contains("cannot spread a Set<int32> into an object literal: its contents are not fields; copy the entries with a loop"), "a Set spread: " + text;
	assert errors.length == 2, "a class instance spread is accepted: " + text;
}
