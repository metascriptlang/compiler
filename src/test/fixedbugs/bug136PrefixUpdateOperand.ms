// bug136 — prefix ++/-- bound tighter than member and index access
//
// Symptom:    `++a[1]` incremented the ARRAY and then indexed it: the C target
//             ran and threw "index 1 out of bounds (length 0)", the Raiser
//             target trapped on "array handle out of bounds: 1". `++o.n` failed
//             to type-check ("Property 'n' does not exist on type 'int32'").
//             Postfix `a[1]++` / `o.n++` were fine.
// Root cause: src/parser/expressions/core.ms — the prefix update parsed its
//             operand with parsePrimary, so the postfix chain (`[i]`, `.n`,
//             `()`) was applied to the UpdateExpr instead of to its operand.
// Fix:        the operand is a postfix chain with no binary op, the same shape
//             typeof/void/delete already used (parseExprWithPrec at 99), with
//             `as` rebound outside the prefix op. The checker now also rejects
//             increment/decrement on a non-numeric operand instead of
//             defaulting the result to int32.

interface B136Counter { n: int32; }

test "bug136: prefix update reaches the array element" {
	const a: int32[] = [4, 7];
	const v = ++a[1];
	assert v == 8;
	assert a[1] == 8;
	assert a[0] == 4;
	--a[0];
	assert a[0] == 3;
}

test "bug136: prefix update reaches the member" {
	const o: B136Counter = { n: 4 };
	const v = ++o.n;
	assert v == 5;
	assert o.n == 5;
	--o.n;
	assert o.n == 4;
}

test "bug136: postfix on member and element still yields the old value" {
	const o: B136Counter = { n: 4 };
	const a: int32[] = [9];
	assert o.n++ == 4;
	assert a[0]-- == 9;
	assert o.n == 5;
	assert a[0] == 8;
}
