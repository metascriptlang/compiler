// bug302 — a write through asBytes() reached an immutable string's payload
//
// Symptom:    `const b = s.asBytes(); b[0] = 65; b.push(66);` changed `s` in place on
//             C (`AxxxB`, length 5) and segfaulted on a literal (a write into
//             .rodata); JS wrote into a private copy and printed `xxxx`.
// Root cause: asBytes returned a writable `uint8[]` that is a zero-copy view of the
//             string's payload, while strings are immutable on the MS surface.
// Fix:        asBytes returns `Readonly<uint8[]>` on every tier, so the checker's
//             read-only view rules refuse index writes, mutating methods and the
//             conversion back to `uint8[]`; `slice()` of the view is a mutable copy.

import { compileToCWithStd, compileProjectToJSWithStd } from "../helpers";

function cError(body: string): string {
	const c = compileToCWithStd(`function main(): void { const s: string = "x".repeat(4); ${body} } main();`);
	return c.ok ? "compiled" : c.error;
}

test "bug302: an index write through asBytes() is refused" {
	assert cError(`const b = s.asBytes(); b[0] = 65;`).includes("cannot write through Readonly<Span<uint8>>");
}

test "bug302: a mutating method through asBytes() is refused" {
	assert cError(`const b = s.asBytes(); b.push(66);`).includes("'push' mutates its receiver");
}

test "bug302: the view does not convert back to a mutable uint8[]" {
	assert cError(`const b: uint8[] = s.asBytes();`).includes("never converts back to the mutable type");
}

test "bug302: the JS backend refuses the same write" {
	const out = compileProjectToJSWithStd([{ entryPath: "test/main.ms", entrySource: `
		function main(): void { const s: string = "hello"; const b = s.asBytes(); b[0] = 74; console.log(s); }
		main();
	` }], "test/main.ms");
	assert out.includes("cannot write through Readonly<Span<uint8>>"), out.slice(0, 300);
}

test "bug302: reads through the view see the bytes and a sliced copy is mutable" {
	const s = "x".repeat(4);
	const view = s.asBytes();
	const copy = view.slice(0, view.length);
	copy[0] = 65;
	copy.push(66);
	assert view.length == 4 && view[0] == 120 && copy.asString() == "AxxxB" && s == "xxxx";
}
