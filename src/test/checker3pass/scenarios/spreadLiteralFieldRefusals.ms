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
