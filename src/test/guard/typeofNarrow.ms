// nim-guard: a typeof-narrowed union read reaches C as its active slot, and a closure or string
//   member of a tagged union is carried, copied and released as itself on BOTH backends
//
// INVARIANT (reference: an implicit conversion sits at EVERY position a value is consumed — call
//   argument, operand, callee, condition — and a variant's active field is read only through its
//   discriminator): `int32 | ((prev: int32) => int32)` calls its closure slot after
//   `typeof v === "function"`, `string | int32` adds or measures its active slot, and the union's
//   copy/destroy hooks touch the string and the closure environment exactly once.
//
// WHAT IT CATCHES: the checker refusing the "function"/"object" tags, clang seeing the whole msUnion
//   at an operand or callee, a closure member emitted as a variant struct of its parameters, a
//   double-released or leaked string/closure environment inside the union, or the js lane regressing.
//
// RED MEANS: exit != 0, DOUBLE-DESTROY in the ledger, or GUARD-OK missing on either lane.
//
// GUARD-JS

function apply(v: int32 | ((prev: int32) => int32), cur: int32): int32 {
	if (typeof v === "function") { return v(cur); }
	return v;
}
function measure(v: string | int32): int32 {
	if (typeof v === "number") { return v + 1; }
	return v.length;
}

let calls = 0;
const tag = "guard";
const bump = (p: int32) => { calls += 1; return p + tag.length; };
let total = 0;
for (let i = 0; i < 3; i += 1) {
	total += apply(bump, i);
	total += apply(i, 0);
}
const s = "abc" + "def";
total += measure(s) + measure(10);
if (total == 38 && calls == 3) {
	console.log("GUARD-OK");
} else {
	console.log("GUARD-FAIL " + total.toString() + " " + calls.toString());
}
