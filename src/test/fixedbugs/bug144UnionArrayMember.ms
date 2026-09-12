// bug144 — an array member of a tagged union was never wrapped at a call site
// Symptom: `function pick(v: int32[] | int32)` called as `pick([1, 2, 3])` passed the raw array pointer where
//          the `msUnion*` parameter was expected (no `_tag`/`.v0` construction, clang silent), so
//          `typeof v === "object"` read the array's length as the tag and `v.length` printed garbage; the same
//          shape is every `setItems([...])` on a signal whose setter takes `T | ((prev: T) => T)`.
// Root cause: widenVariantToUnion found the slot through primitiveMemberIndexInUnion, which matches a Ref
//             member by identity only — a fresh literal or another variable of the same array type never
//             hits — and would then have dereferenced the pointer into a by-value slot that holds a pointer.
// Fix: fall back to structural identity (sameType) over the members, and dereference only for a member
//      whose slot holds a struct by value.

function len144(v: int32[] | int32): int32 {
	if (typeof v === "object") { return v.length; }
	return v;
}

function applyT144<T>(v: T | ((prev: T) => T), cur: T): T {
	if (typeof v === "function") { return v(cur); }
	return v;
}

function total144(xs: int32[]): int32 {
	let sum = 0;
	for (const x of xs) sum += x;
	return sum;
}

test "an array literal is wrapped into the union slot" {
	assert len144([1, 2, 3]) == 3;
	assert len144(7) == 7;
}

test "an array variable is wrapped into the union slot" {
	const xs: int32[] = [4, 5];
	assert len144(xs) == 2;
	assert xs.length == 2;
}

test "a value-or-updater setter shape carries an array through both branches" {
	const next: int32[] = applyT144<int32[]>([1, 2, 3], []);
	assert total144(next) == 6;
	const grown: int32[] = applyT144<int32[]>((prev: int32[]) => [prev.length, prev.length], [9, 9, 9]);
	assert total144(grown) == 6;
}
