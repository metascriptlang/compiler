import { checkOnly } from "../helpers";

const ORDER_HINT = "the same members in another order";

const SRC_REORDERED = `
interface A { v: int32 | string | null; }
interface B { v: string | int32 | null; }
function show(v: string | int32): string { return typeof v == "string" ? v : "n"; }
function f(a: int32 | string, x: A, y: B): void {
	const c: string | int32 = a;
	let d: string | int32 = 1;
	d = a;
	show(a);
	x.v = y.v;
}
`;

const SRC_WIDER = `
function f(a: int32 | string): void {
	const g: boolean | int32 | string = a;
}
`;

const SRC_NARROWED = `
function show(v: string | int32): string { return typeof v == "string" ? v : "n"; }
function wide(v: boolean | string | int32 | null): string { return "w"; }
function f(a: int32 | string): void {
	const x: int32 | string = "hello";
	show(x);
	wide(x);
	if (typeof a == "string") show(a);
	const c: string | int32 = x;
}
`;

test "a union written in another member order is refused, naming the order" {
	const errors = checkOnly(SRC_REORDERED).errors;
	let named = 0;
	for (const e of errors) if (e.contains(ORDER_HINT)) named += 1;
	assert named == 4, "declaration, assignment, argument and nullable field must name the order: " + errors.join("\n");
}

test "a wider union refusal does not claim a reorder" {
	const text = checkOnly(SRC_WIDER).errors.join("\n");
	assert text.contains("is not assignable to type 'boolean | int32 | string'"), "widening must stay refused: " + text;
	assert !text.contains(ORDER_HINT), "a different member set is not a reorder: " + text;
}

test "a narrowed union reference fits a union in another order" {
	const result = checkOnly(SRC_NARROWED);
	assert result.errors.length == 0, "a narrowed member converts into any union holding it: " + result.errors.join("\n");
}
