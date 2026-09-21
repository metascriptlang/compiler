// bug198 — a nullable field whose payload mentions the type parameter made a generic function unusable as a value argument
// Symptom: `comp(Widget, { each: () => [1, 2] })` with
//          `Widget<T>(props: { each: () => T[]; key?: ((item: T) => number) | null })` reported
//          "Argument type mismatch in 'comp' arg 0: got function, expected function"; the same props
//          with the field required, with the payload concrete, or with a non-nullable `T[]` field compiled.
// Root cause: `X | null` becomes a Maybe carrier only once X is concrete (substituteAllParams →
//             nullableUnionOf), so the uninstantiated signature still held the union where the formal
//             substituted from the inferred bindings already held the carrier. isAssignable read the two
//             spellings as unrelated kinds and fieldReprMismatch called every union-against-struct pair
//             a reinterpret.
// Fix: an open nullable union and a Maybe carrier relate by payload, in the assignability relation and
//      in the field repr gate alike.

import { compileToCWithStd } from "../helpers";

const PRELUDE = `
function comp<P>(C: (props: P) => number, props: P): number { return C(props); }
function widgetNullableFn<T>(props: { each: () => T[]; key?: ((item: T) => number) | null }): number { return props.each().length as number; }
function widgetNullableParam<T>(props: { each: () => T[]; key: T | null }): number { return props.each().length as number; }
function widgetRequiredFn<T>(props: { each: () => T[]; key: (item: T) => number }): number { return props.each().length as number; }
function widgetConcreteFn<T>(props: { each: () => T[]; key?: ((item: int32) => number) | null }): number { return props.each().length as number; }
function takesNullableFn(f: ((item: int32) => number) | null): number { return f == null ? 0 : f(1); }
`;

function errorsOf(body: string): string {
	const r = compileToCWithStd(PRELUDE + "function main(): void { " + body + " }");
	if (r.ok) return "";
	return r.error;
}

test "bug198: a generic callee binds its type parameter to props carrying a nullable function of T" {
	assert errorsOf("console.log(comp(widgetNullableFn, { each: () => [1, 2] }).toString());") == "";
}

test "bug198: the same holds when the nullable field is the type parameter itself" {
	assert errorsOf("console.log(comp(widgetNullableParam, { each: () => [1, 2], key: 3 }).toString());") == "";
}

test "bug198: supplying the nullable function at the call site still binds" {
	assert errorsOf("console.log(comp(widgetNullableFn, { each: () => [1, 2], key: (item: int32): number => item }).toString());") == "";
}

test "bug198: a required function of T and a nullable function of a concrete type keep binding" {
	assert errorsOf("console.log(comp(widgetRequiredFn, { each: () => [1, 2], key: (item: int32): number => item }).toString());") == "";
	assert errorsOf("console.log(comp(widgetConcreteFn, { each: () => [1, 2] }).toString());") == "";
}

test "bug198: a nullable payload that does not fit is still refused" {
	const e = errorsOf("console.log(takesNullableFn((item: string): number => 1).toString());");
	assert e.contains("Argument type mismatch in 'takesNullableFn' arg 0"), e;
}
