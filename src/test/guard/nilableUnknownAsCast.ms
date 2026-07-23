// nim-guard: a nilable-POINTER union (`unknown|null`, `Ref|null`) `as`-cast is a
// VALUE copy, not a tagged-union storage-borrow.
//
// INVARIANT: `const a = call() as T` where call returns a nilable-pointer union
//   (`unknown|null`) must emit `T a = call()` (value), NOT `T* a = &(call())`
//   (union storage-borrow). A nilable pointer collapses to a bare pointer
//   (Nim options.nim SomePointer split: nil is the sentinel, no `{value,present}`
//   wrapper, no variant storage to borrow). Only a genuine tagged union has
//   borrowable variant storage.
// NIM-REF: §1 "unknown top type" collapse + "Value-type Maybe unwrap operators"
//   OPEN-sibling. isUnionNarrowing (codegen) tested only `srcType.kind === Union`,
//   TRUE for a pointer-collapsed nullable too -> `void** a = &(rvalue)` ->
//   clang "cannot take the address of an rvalue". Fix: exclude
//   unwrapRefNullUnion != null.
//
// WHAT IT CATCHES: isUnionNarrowing (or genTypeAssertion) regressing to borrow a
//   nilable-pointer union's "storage" -> RED = build failure (address of rvalue)
//   or a wrong pointer read. Proven RED on the pre-fix binary.

type H = unknown;
class Node2 { v: number; }

function main(): void {
	const m = new Map<string, H>();
	const n = new Node2();
	n.v = 7;
	m.set("a", n as unknown as H);
	const got = m.get("a") as H;         // unknown|null as unknown — the exact repro
	const node = got as Node2;           // unknown -> Ref (legal pointer cast)
	if (node.v !== 7) { throw "GUARD RED: nilable-unknown as-cast lost the pointer"; }
	console.log("nilableUnknownAsCast ok");
}
main();
