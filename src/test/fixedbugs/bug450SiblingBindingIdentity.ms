// bug450 — two sibling-scope bindings of one name, each captured, shared one env slot
//
// Symptom:    on C, `{ const x = "first"; push(() => x) } { const x = "second"; push(() => x) }`
//             made both closures read "second"; with different types
//             (`const x: string` then `const x: int32`) the emitted C did not
//             compile. JS was correct.
// Root cause: src/transform/lowering/lambdaLiftingRename.ms renamed a binding
//             only when it shadowed a visible one, so disjoint sibling scopes
//             kept one name, and the name-keyed capture sets and env fields
//             merged the two bindings.
// Fix:        the renamer gives every repeated binding name within a frame a
//             fresh name, visible or not.
//
// Guarded end-to-end by corpus/programs/920-closureSiblingBindings.ms.

type B450Thunk = () => string;

function b450SiblingBlocks(): string {
	const fs: B450Thunk[] = [];
	{
		const x: string = "first";
		fs.push((): string => x);
	}
	{
		const x: string = "second";
		fs.push((): string => x);
	}
	return fs[0]() + "," + fs[1]();
}

function b450SiblingIfBlocks(): string {
	let a: B450Thunk | null = null;
	if (true) {
		const x: string = "then";
		a = (): string => x;
	}
	if (true) {
		const x: string = "later";
		const b = (): string => x;
		b();
	}
	return a!();
}

function b450SiblingTypes(): string {
	let out: string = "";
	{
		const x: string = "s";
		const f = (): string => x + "1";
		out = out + f();
	}
	{
		const x: int32 = 7;
		const g = (): int32 => x + 1;
		out = out + g().toString();
	}
	return out;
}

test "bug450: sibling blocks each keep their captured binding" {
	assert b450SiblingBlocks() == "first,second";
}

test "bug450: a later sibling if-block does not overwrite an earlier capture" {
	assert b450SiblingIfBlocks() == "then";
}

test "bug450: sibling bindings of different types each get their own slot" {
	assert b450SiblingTypes() == "s18";
}
