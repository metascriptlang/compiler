import { compileToC } from "../helpers";

const decls = `
struct Inner { n: int32; }
struct Pair = match (ok: boolean) {
	true => { value: string, n: int32, inner: Inner },
	false => { error: string },
}
struct Either<T, E> = match (ok: boolean) {
	true => { value: T },
	false => { error: E },
}
type Shared = match (ok: boolean) {
	true => { value: string },
	false => { error: string },
}
`;

test "valueUnionParamWrite: a write through a value-union parameter is refused like a struct parameter" {
	const refused = [
		{ name: "a field write after narrowing", body: "export function run(x: Pair): void { if (x.ok) { x.value = \"changed\"; } }", refusal: "cannot mutate value-type parameter 'x'" },
		{ name: "a compound write", body: "export function run(x: Pair): void { if (x.ok) { x.n += 1; } }", refusal: "cannot mutate value-type parameter 'x'" },
		{ name: "a nested field write", body: "export function run(x: Pair): void { if (x.ok) { x.inner.n = 1; } }", refusal: "cannot mutate value-type parameter 'x'" },
		{ name: "a generic value union", body: "export function run(x: Either<string, string>): void { if (x.ok) { x.value = \"changed\"; } }", refusal: "cannot mutate value-type parameter 'x'" },
		{ name: "a const binding", body: "export function run(): void { const x: Pair = { ok: true, value: \"a\", n: 1, inner: { n: 1 } }; if (x.ok) { x.value = \"changed\"; } }", refusal: "'x' is const" },
		{ name: "a for-of element", body: "export function run(xs: Pair[]): void { for (const x of xs) { if (x.ok) { x.value = \"changed\"; } } }", refusal: "cannot mutate value-type loop variable 'x'" },
	];
	for (const item of refused) {
		const result = compileToC(decls + item.body);
		assert !result.ok && result.error.contains(item.refusal), item.name + (result.ok ? " compiled" : ": " + result.error);
	}
}

test "valueUnionParamWrite: a reference union parameter and a local copy stay writable" {
	const kept = [
		{ name: "a reference union parameter", body: "export function run(x: Shared): void { if (x.ok) { x.value = \"changed\"; } }" },
		{ name: "a ref parameter", body: "export function run(ref x: Pair): void { if (x.ok) { x.value = \"changed\"; } }" },
		{ name: "a local copy", body: "export function run(x: Pair): string { let y = x; if (y.ok) { y.value = \"changed\"; return y.value; } return \"\"; }" },
	];
	for (const item of kept) {
		const result = compileToC(decls + item.body);
		assert result.ok, item.name + (result.ok ? "" : ": " + result.error);
	}
}
