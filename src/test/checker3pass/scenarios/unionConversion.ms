import { checkOnly } from "../helpers";

test "a union converts into a union holding every member it holds" {
	const src = `
function show(u: boolean | int32 | string): string { return "w"; }
function narrow(): int32 | string { return 1; }
function ret(): boolean | int32 | string { const n = narrow(); return n; }
let w: boolean | int32 | string = false;
w = narrow();
const g: boolean | int32 | string = narrow();
show(narrow());
`;
	const errors = checkOnly(src).errors;
	assert errors.length == 0, "declaration, assignment, argument and return convert: " + errors.join("\n");
}

test "as converts between unions sharing a member" {
	const src = `
function narrow(): int32 | string { return 1; }
const wider = narrow() as boolean | int32 | string;
const overlap = narrow() as boolean | string;
`;
	const errors = checkOnly(src).errors;
	assert errors.length == 0, "a wider or overlapping target converts: " + errors.join("\n");
}

test "as between unions with no member in common is refused" {
	const src = `
function narrow(): int32 | string { return 1; }
const none = narrow() as boolean | int32[];
`;
	const text = checkOnly(src).errors.join("\n");
	assert text.contains("cannot convert int32 | string to int32[] | boolean — no member of 'int32 | string' is a member of 'int32[] | boolean'"), "a disjoint target is refused: " + text;
}

test "a union member widening losslessly to a target number converts" {
	const src = `
function narrow(): int32 | string { return 1; }
function small(): uint8 | boolean { return 1; }
const g: float64 | string = narrow();
const h: int16 | boolean = small();
const i = narrow() as float64 | string;
`;
	const errors = checkOnly(src).errors;
	assert errors.length == 0, "int32 into float64 and uint8 into int16 are lossless: " + errors.join("\n");
}

test "a union member that would lose its value converting to the target number is refused by name" {
	const src = `
function wide(): int64 | string { return 1; }
const g: float64 | string = wide();
`;
	const text = checkOnly(src).errors.join("\n");
	assert text.contains("'int64' to 'float64' may lose integer precision above 2^53"), "the lossy member pair is named: " + text;
}

test "as from a union to a nullable type holding none of its members is refused" {
	const src = `
function narrow(): int32 | string { return 1; }
const none = narrow() as boolean | null;
`;
	const text = checkOnly(src).errors.join("\n");
	assert text.contains("no member of 'int32 | string' is a member of 'boolean'"), "a disjoint nullable target is refused: " + text;
}

test "as from a union holding string to a set of string literals is not refused" {
	const src = `
type Align = "auto" | "center";
function wire(): int32 | string { return "auto"; }
const a = wire() as Align | null;
const b = wire() as Align;
`;
	const errors = checkOnly(src).errors;
	assert errors.length == 0, "a string literal is a member of string, so the unions overlap: " + errors.join("\n");
}
