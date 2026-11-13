import { checkOnly } from "../helpers";
import { resolveAnnotation } from "../../../checker/resolvePass";
import { sameType } from "../../../checker/compat";
import { Type } from "../../../ast/node";
import { isReadonlyView, isReadonlyArray, typeDisplayName } from "../../../checker/types";

function annotated(text: string): Type {
	const ctx = checkOnly("const probe = 1;").ctx;
	return resolveAnnotation(text, ctx, 1, 1);
}

function readonlyArrayMismatch(written: string, plain: string): string {
	const a = annotated(written);
	const b = annotated(plain);
	if (!isReadonlyArray(a) || isReadonlyView(a)) return written + " is not a readonly array: " + typeDisplayName(a);
	if (!sameType(a, b)) return written + " resolved to " + typeDisplayName(a) + ", " + plain + " to " + typeDisplayName(b);
	return "";
}

function refusals(src: string): string {
	return checkOnly(src).errors.join("\n");
}

const ITEM = "class Item { n: int32 = 0; }\nstruct Cell { x: int32; }\nfunction take(i: Item): void { i.n += 1; }\n";

test "readonly-annotation: readonly T[] is the array of T itself, marked readonly, not a view of it" {
	assert readonlyArrayMismatch("readonly int32[]", "int32[]") == "", readonlyArrayMismatch("readonly int32[]", "int32[]");
	assert readonlyArrayMismatch("readonly string[]", "string[]") == "", readonlyArrayMismatch("readonly string[]", "string[]");
	assert typeDisplayName(annotated("readonly string[]")) == "readonly string[]";
	assert isReadonlyView(annotated("Readonly<int32[]>")), "Readonly<T[]> stays the deep view";
}

test "readonly-annotation: readonly T[][] makes only the outer array readonly" {
	const t = annotated("readonly int32[][]");
	assert readonlyArrayMismatch("readonly int32[][]", "int32[][]") == "", readonlyArrayMismatch("readonly int32[][]", "int32[][]");
	assert !isReadonlyArray(t.typeReturn.typeReturn), typeDisplayName(t);
}

test "readonly-annotation: readonly (A | B)[] keeps the union under the array" {
	assert readonlyArrayMismatch("readonly (int32 | string)[]", "(int32 | string)[]") == "", readonlyArrayMismatch("readonly (int32 | string)[]", "(int32 | string)[]");
}

test "readonly-annotation: readonly A[] | B[] marks only the first member" {
	const t = annotated("readonly int32[] | string[]");
	assert !isReadonlyArray(t) && !isReadonlyView(t), typeDisplayName(t);
}

test "readonly-array: an element read through readonly T[] is a T, written through and handed on as one" {
	for (const body of [
		"function f(xs: readonly Item[]): void { xs[0].n += 1; take(xs[0]); for (const x of xs) take(x); }\n",
		"function f(xs: readonly string[][]): void { xs[0].push(\"a\"); }\n",
		"function f(xs: readonly Item[]): Item[] { return xs.slice(0); }\n",
		"function f(xs: readonly Item[]): number { return xs.map((x) => x.n).length + xs.indexOf(xs[0]); }\n",
		"function first<T>(xs: readonly T[]): T { return xs[0]; }\nconst all: Item[] = [new Item()];\ntake(first(all));\n",
		"function v(xs: Readonly<Item[]>): int32 { return xs.length; }\nfunction f(xs: readonly Item[]): int32 { return v(xs); }\n",
		"const all: Item[] = [new Item()];\nconst ro: readonly Item[] = all;\nconst again: readonly Item[] = ro;\ntake(again[0]);\n",
		"function f(xs: ReadonlyArray<Item>): void { xs[0].n = 2; }\n",
	]) {
		const errors = refusals(ITEM + body);
		assert errors == "", body + " -> " + errors;
	}
}

test "readonly-array: a write into the array's own slots or length is refused" {
	for (const body of [
		"function f(xs: readonly Item[], i: Item): void { xs[0] = i; }\n",
		"function f(xs: readonly Item[]): void { xs.length = 0; }\n",
		"function f(xs: readonly Cell[]): void { xs[0].x = 1; }\n",
		"function f(xs: readonly int32[]): void { xs[0] += 1; }\n",
		"function m(ref c: Cell): void {}\nfunction f(xs: readonly Cell[]): void { m(xs[0]); }\n",
	]) {
		const text = refusals(ITEM + body);
		assert text.contains("a readonly array's slots and length are not written through it"), body + " -> " + text;
	}
}

test "readonly-array: a method that writes its receiver is refused" {
	for (const call of ["xs.push(i)", "xs.pop()", "xs.splice(0, 1)", "xs.reverse()", "xs.shift()", "xs.sort((a, b) => a.n - b.n)"]) {
		const body = "function f(xs: readonly Item[], i: Item): void { " + call + "; }\n";
		const text = refusals(ITEM + body);
		assert text.contains("is a readonly array"), body + " -> " + text;
	}
}

test "readonly-array: a readonly array never converts back to a writable one" {
	for (const body of [
		"function f(xs: readonly Item[]): void { const w: Item[] = xs; }\n",
		"function g(xs: Item[]): void {}\nfunction f(xs: readonly Item[]): void { g(xs); }\n",
		"function f(xs: readonly Item[]): Item[] { return xs; }\n",
		"function f(xs: readonly Item[] | null): Item[] | null { return xs; }\n",
	]) {
		const text = refusals(ITEM + body);
		assert text.contains("a readonly array never converts back to the mutable type"), body + " -> " + text;
	}
	const cast = refusals(ITEM + "function f(xs: readonly Item[]): void { const w = xs as Item[]; }\n");
	assert cast.contains("cannot cast away readonly Item[]"), cast;
	const deep = refusals(ITEM + "function f(xs: Readonly<Item[]>): void { const w: readonly Item[] = xs; }\n");
	assert deep.contains("a read-only view never converts back"), deep;
}

test "readonly-array: a readonly array of Unowned elements takes a strong array, and is never written" {
	const head = "class P { n: int32 = 1; }\nfunction bump(p: P): void { p.n += 1; }\n";
	const ok = refusals(head + "function f(xs: readonly Unowned<P>[]): void { bump(xs[0]); for (const x of xs) bump(x); }\nconst all: P[] = [new P()];\nf(all);\n");
	assert ok == "", ok;
	const push = refusals(head + "function f(xs: readonly Unowned<P>[], p: P): void { xs.push(p); }\n");
	assert push.contains("is a readonly array"), push;
	const back = refusals(head + "function f(xs: readonly Unowned<P>[]): void { const w: Unowned<P>[] = xs; }\n");
	assert back.contains("never converts back"), back;
}

test "readonly-annotation: readonly without an array suffix is refused" {
	const ctx = checkOnly("const probe = 1;").ctx;
	const before = ctx.errors.length;
	resolveAnnotation("readonly int32", ctx, 1, 1);
	assert ctx.errors.length == before + 1;
}

const GENERIC_TABLE = "struct Account { id: string; }\nstruct Table<T> { name: string; columns: Vec<string>; }\nstruct Pair<T> { a: int32; b: int32; }\n";

test "readonly-annotation: Readonly over a generic instance whose body carries a ref is a view, over a pod body a value" {
	const ctx = checkOnly(GENERIC_TABLE + "const probe = 1;").ctx;
	const view = resolveAnnotation("Readonly<Table<Account>>", ctx, 1, 1);
	assert isReadonlyView(view), typeDisplayName(view);
	const pod = resolveAnnotation("Readonly<Pair<Account>>", ctx, 1, 1);
	assert !isReadonlyView(pod), typeDisplayName(pod);
}

test "readonly-annotation: a write through Readonly over a generic instance is refused" {
	const decl = "let t: Readonly<Table<Account>> = { name: \"a\", columns: [\"id\"] };";
	for (const write of [
		"function f(): void { " + decl + " t.name = \"x\"; }\n",
		"function f(): void { " + decl + " t.columns.push(\"y\"); }\n",
		"function f(): void { " + decl + " let c = t.columns; c.push(\"y\"); }\n",
		"function m(ref t: Table<Account>): void {}\nfunction f(): void { " + decl + " m(t); }\n",
		"function f(t: Readonly<Table<Account>>): Table<Account> { return t; }\n",
	]) {
		const text = checkOnly(GENERIC_TABLE + write).errors.join("\n");
		assert text.contains("read-only view"), write + " -> " + text;
	}
}

test "utility-type: ReadonlyArray<T> is readonly T[]" {
	assert readonlyArrayMismatch("ReadonlyArray<int32>", "int32[]") == "", readonlyArrayMismatch("ReadonlyArray<int32>", "int32[]");
	assert readonlyArrayMismatch("ReadonlyArray<int32 | string>", "(int32 | string)[]") == "", readonlyArrayMismatch("ReadonlyArray<int32 | string>", "(int32 | string)[]");
}

test "utility-type: a ReadonlyArray parameter takes an array and refuses a write" {
	const ok = checkOnly("function n(a: ReadonlyArray<int32>): int32 { return a.length + a[0]; }\nconst xs: int32[] = [1, 2];\nconst r = n(xs);\n");
	assert ok.errors.length == 0, ok.errors.join("; ");
	const bad = checkOnly("function n(a: ReadonlyArray<int32>): void { a.push(3); }\n");
	assert bad.errors.length > 0;
}

test "utility-type: NonNullable<T> drops null from a nullable union" {
	const ok = checkOnly("function f(x: string | null): NonNullable<string | null> { return x!; }\nconst s: string = f(\"a\");\n");
	assert ok.errors.length == 0, ok.errors.join("; ");
	const bad = checkOnly("const s: NonNullable<string | null> = null;\n");
	assert bad.errors.length > 0;
}

test "utility-type: NonNullable<T> of a non-nullable type is that type" {
	const ok = checkOnly("const n: NonNullable<int32> = 4;\nconst m: int32 = n;\n");
	assert ok.errors.length == 0, ok.errors.join("; ");
}

test "void-arm: a conditional used as a value refuses a void arm beside a value arm" {
	const prelude = "function log(s: string): void { console.log(s); }\n";
	const message = "cannot have a 'void' arm";
	for (const body of [
		"function f(c: boolean): boolean { return c ? log(\"x\") : true; }\n",
		"const r = true ? log(\"y\") : 5;\n",
		"function g(c: boolean): void { const r = c ? \"s\" : log(\"z\"); }\n",
	]) {
		const text = checkOnly(prelude + body).errors.join("\n");
		assert text.contains(message), body + " -> " + text;
	}
}

test "void-arm: a conditional used as a statement or of two void arms is accepted" {
	const prelude = "function log(s: string): void { console.log(s); }\n";
	for (const body of [
		"function f(c: boolean): void { c ? log(\"x\") : 5; }\n",
		"function g(c: boolean): void { c ? log(\"a\") : log(\"b\"); }\n",
		"const h = (c: boolean): void => c ? log(\"a\") : 5;\n",
	]) {
		const errors = checkOnly(prelude + body).errors;
		assert errors.length == 0, body + " -> " + errors.join("; ");
	}
}

test "tuple-annotation: [A, B][] is an array of tuples and [A, B[]] stays a tuple" {
	const arrayOfTuple = typeDisplayName(annotated("[string, int32][]"));
	const tuple = typeDisplayName(annotated("[string, int32]"));
	assert arrayOfTuple == tuple + "[]", arrayOfTuple;
	const grid = typeDisplayName(annotated("[string, int32][][]"));
	assert grid == tuple + "[][]", grid;
	const tupleOfArray = typeDisplayName(annotated("[int32[], string]"));
	assert tupleOfArray == "[int32[], string]", tupleOfArray;
}

test "tuple-annotation: the empty tuple is still refused" {
	const ctx = checkOnly("const probe = 1;").ctx;
	const before = ctx.errors.length;
	resolveAnnotation("[]", ctx, 1, 1);
	assert ctx.errors.length == before + 1;
}
