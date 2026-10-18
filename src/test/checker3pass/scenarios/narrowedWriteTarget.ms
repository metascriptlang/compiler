import { checkOnly } from "../helpers";

const PRELUDE = "struct Packet { values: Vec<uint32> | null; }\n"
	+ "struct Q { k: int32; }\n"
	+ "struct P { q: Q | null; n: int32 | null; }\n";

const NO_INDEX = "has no '[]' operator";
const READONLY_VIEW = "read-only";

function errorsOf(body: string): string {
	return checkOnly(PRELUDE + body).errors.join("\n");
}

test "the receiver of an element write is narrowed by a null check" {
	const text = errorsOf("function f(): void { let v: Vec<uint32> | null = [1, 2]; if (v !== null) { v[0] = 7; } }\n");
	assert text == "", "v[0] = 7 after the guard must check: " + text;
}

test "the receiver of an element write is narrowed by an early-return guard" {
	const text = errorsOf("function f(): void { let v: Vec<uint32> | null = [1, 2]; if (v === null) return; v[0] = 7; }\n");
	assert text == "", "v[0] = 7 after an early return must check: " + text;
}

test "the receiver of an element compound write is narrowed" {
	const text = errorsOf("function f(): void { let v: Vec<uint32> | null = [1, 2]; if (v !== null) { v[0] += 5; } }\n");
	assert text == "", "v[0] += 5 after the guard must check: " + text;
}

test "the receiver of an element write through a ref field is narrowed" {
	const text = errorsOf("function f(ref packet: Packet): void { if (packet.values !== null) { packet.values[0] = 7; } }\n");
	assert text == "", "packet.values[0] = 7 after the guard must check: " + text;
}

test "the receiver of an element write through an array alias and a map is narrowed" {
	for (const body of ["let a: uint32[] | null = [1, 2]; if (a !== null) { a[0] = 7; }",
		"let a: number[] | null = [1, 2]; if (a !== null) { a[0] = 7; }",
		"let m: Map<string, int32> | null = new Map<string, int32>(); if (m !== null) { m[\"a\"] = 1; }",
		"let rows: Vec<Vec<uint32> | null> = [[1]]; let r = rows[0]; if (r !== null) { r[0] = 8; }"]) {
		const text = errorsOf("function f(): void { " + body + " }\n");
		assert text == "", "a narrowed receiver must check: " + body + " -> " + text;
	}
}

test "the receiver of a field write through a nullable value struct is narrowed" {
	const text = errorsOf("function f(ref p: P): void { if (p.q !== null) { p.q.k = 9; } }\n");
	assert text == "", "p.q.k = 9 after the guard must check: " + text;
}

test "the target of a compound assignment is narrowed" {
	assert errorsOf("function f(x: int32 | null): void { if (x !== null) { x += 1; } }\n") == "", "x += 1 after the guard must check";
	assert errorsOf("function f(ref p: P): void { if (p.n !== null) { p.n += 1; } }\n") == "", "p.n += 1 after the guard must check";
}

test "a definite assignment target reads the declared type, so a literal types against it" {
	const text = errorsOf("function f(x: int32 | null): void { if (x === null) { x = 3; } }\n");
	assert text == "", "x = 3 in the null branch must check: " + text;
	const nullWrite = errorsOf("function f(x: int32 | null): void { if (x !== null) { x = null; } }\n");
	assert nullWrite == "", "a narrowed variable still accepts a null write through its declared type: " + nullWrite;
}

test "an element write through an unguarded nullable receiver is refused" {
	const text = errorsOf("function f(): void { let v: Vec<uint32> | null = [1, 2]; v[0] = 7; }\n");
	assert text.contains(NO_INDEX), "v[0] = 7 without a guard must stay refused: " + text;
	const field = errorsOf("function f(ref packet: Packet): void { packet.values[0] = 7; }\n");
	assert field.contains(NO_INDEX), "packet.values[0] = 7 without a guard must stay refused: " + field;
}

test "a field write through an unguarded nullable struct is refused" {
	const text = errorsOf("function f(ref p: P): void { p.q.k = 9; }\n");
	assert text != "", "p.q.k = 9 without a guard must stay refused";
}

test "a narrowed receiver that is a read-only view is still refused" {
	const text = errorsOf("function f(v: Readonly<Vec<uint32>> | null): void { if (v !== null) { v[0] = 7; } }\n");
	assert text.contains(READONLY_VIEW), "a write through a narrowed read-only view must stay refused: " + text;
	assert !text.contains(NO_INDEX), "the refusal names the view, not a missing operator: " + text;
}
