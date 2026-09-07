// Sibling helper for bug135 — module A of the cross-module type-arg pair.
//
// Every spray line places '<' in the SAME column, repeated across a line range,
// so the sibling module's `Result.err` collides wherever it lands inside that
// range. One line of drift in either file would otherwise disarm the guard.

function pick<T, U>(a: T, b: U): T { return a; }

function bug135Spray(): int32 {
	const v01 = pick<int32, boolean>(1, true);
	const v02 = pick<int32, boolean>(1, true);
	const v03 = pick<int32, boolean>(1, true);
	const v04 = pick<int32, boolean>(1, true);
	const v05 = pick<int32, boolean>(1, true);
	const v06 = pick<int32, boolean>(1, true);
	const v07 = pick<int32, boolean>(1, true);
	const v08 = pick<int32, boolean>(1, true);
	const v09 = pick<int32, boolean>(1, true);
	const v10 = pick<int32, boolean>(1, true);
	const v11 = pick<int32, boolean>(1, true);
	const v12 = pick<int32, boolean>(1, true);
	return v01 + v02 + v03 + v04 + v05 + v06 + v07 + v08 + v09 + v10 + v11 + v12;
}

test "bug135helper: explicit type args bind in their own module" {
	assert bug135Spray() == 12;
}
