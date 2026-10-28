import { checkOnly } from "../helpers";
import { resolveAnnotation } from "../../../checker/resolvePass";
import { sameType } from "../../../checker/compat";
import { Type } from "../../../ast/node";
import { isReadonlyView, typeDisplayName } from "../../../checker/types";

function annotated(text: string): Type {
	const ctx = checkOnly("const probe = 1;").ctx;
	return resolveAnnotation(text, ctx, 1, 1);
}

function viewMismatch(written: string, wrap: string): string {
	const a = annotated(written);
	const b = annotated(wrap);
	if (!isReadonlyView(a)) return written + " is not a view: " + typeDisplayName(a);
	if (!sameType(a, b)) return written + " resolved to " + typeDisplayName(a) + ", " + wrap + " to " + typeDisplayName(b);
	return "";
}

test "readonly-annotation: readonly T[] decodes to the deep Readonly view of T[], as Readonly<T[]>" {
	assert viewMismatch("readonly int32[]", "Readonly<int32[]>") == "", viewMismatch("readonly int32[]", "Readonly<int32[]>");
	assert viewMismatch("readonly string[]", "Readonly<string[]>") == "", viewMismatch("readonly string[]", "Readonly<string[]>");
}

test "readonly-annotation: readonly T[][] makes only the outer array the view" {
	assert viewMismatch("readonly int32[][]", "Readonly<int32[][]>") == "", viewMismatch("readonly int32[][]", "Readonly<int32[][]>");
	assert !isReadonlyView(annotated("Readonly<int32[]>[]")), "the element view must not make the outer array a view";
}

test "readonly-annotation: readonly (A | B)[] keeps the union under the array" {
	assert viewMismatch("readonly (int32 | string)[]", "Readonly<(int32 | string)[]>") == "", viewMismatch("readonly (int32 | string)[]", "Readonly<(int32 | string)[]>");
}

test "readonly-annotation: readonly A[] | B[] views only the first member" {
	const t = annotated("readonly int32[] | string[]");
	assert !isReadonlyView(t), typeDisplayName(t);
}

test "readonly-annotation: readonly without an array suffix is refused" {
	const ctx = checkOnly("const probe = 1;").ctx;
	const before = ctx.errors.length;
	resolveAnnotation("readonly int32", ctx, 1, 1);
	assert ctx.errors.length == before + 1;
}

test "utility-type: ReadonlyArray<T> is Readonly<T[]>" {
	assert viewMismatch("ReadonlyArray<int32>", "Readonly<int32[]>") == "", viewMismatch("ReadonlyArray<int32>", "Readonly<int32[]>");
	assert viewMismatch("ReadonlyArray<int32 | string>", "Readonly<(int32 | string)[]>") == "", viewMismatch("ReadonlyArray<int32 | string>", "Readonly<(int32 | string)[]>");
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
