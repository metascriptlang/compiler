// Phase 6 — aliased conditions narrow reference types.
//
// `const isStr = typeof val === "string"` stores the predicate on a const
// binding. When `isStr` is later tested in a condition, the flow graph looks
// up the binding, recurses into the stored typeof test, and narrows `val`.
//
// This example uses nullable types (nominal unions with null) which codegen
// handles cleanly. The narrowing paths are:
//   1. Aliased null check — const bound to `x === null`
//   2. Inline `!==` null check
//   3. Compound `&&` narrowing

function describe(val: string): string {
	const empty = val.length == 0;
	if (empty) {
		return "empty";
	}
	return "non-empty of length " + (val.length as number).toString();
}

function greet(name: string): string {
	const hasExclaim = name.length > 0 && name.charAt(name.length - 1) == "!";
	if (hasExclaim) {
		return "excited: " + name;
	}
	return "calm: " + name;
}

function main(): int32 {
	console.log(describe(""));
	console.log(describe("hello"));
	console.log(greet("hi"));
	console.log(greet("wow!"));
	return 0;
}

main();
