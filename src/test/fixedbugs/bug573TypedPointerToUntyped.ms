// bug573 — a typed pointer stopped reaching an untyped pointer parameter
//
// Symptom:    yoga's `applyStyle(yg: Ptr<void>, ...)` refused `YGNodeNew()`: "got Ptr<YGNode>,
//             expected Ptr<void>", after a bodiless extern struct became a closed struct.
// Root cause: the Ptr arm compared pointees invariantly with no case for the untyped pointer;
//             it had passed only while the extern struct was an open (inferred) type.
// Fix:        `Ptr<T>` converts to `Ptr<void>` (reference typeRel: `pointer` takes `ptr T` as
//             isConvertible); `Ptr<void>` to `Ptr<T>` stays refused, as the reference needs a cast.

import { compileToC } from "../helpers";

const header = `
extern struct Opaque;
extern function newOpaque(): Ptr<Opaque>;
extern function useOpaque(p: Ptr<Opaque>): void;
function erase(p: Ptr<void>): void {}
`;

function errorOf(body: string): string {
	const r = compileToC(header + body);
	return r.ok ? "" : r.error;
}

test "bug573: a typed pointer passes as an untyped pointer" {
	assert errorOf("erase(newOpaque());") == "";
}

test "bug573: a typed pointer initializes an untyped pointer" {
	assert errorOf("const raw: Ptr<void> = newOpaque(); erase(raw);") == "";
}

test "bug573: an untyped pointer does not pass as a typed pointer" {
	assert errorOf("const raw: Ptr<void> = newOpaque(); useOpaque(raw);").contains("got Ptr<void>, expected Ptr<Opaque>");
}

test "bug573: an untyped pointer passes as a typed pointer through a cast" {
	assert errorOf("const raw: Ptr<void> = newOpaque(); useOpaque(raw as Ptr<Opaque>);") == "";
}
