// Symptom: live module scalar constants kept writable storage under Solana, and wide integer folds lost precision.
// Root cause: runtime constant folding did not follow module const initializers and evaluated integer operands as doubles.
// Fix: inline scalar const initializer chains and evaluate integer operations in their declared width.

const WIDE201: uint64 = 18446744073709551615;
const THIRD201: uint64 = WIDE201 / 3;
const LOWEST201: int32 = -2147483648;
const NEGATIVE201: int64 = -9223372036854775807;

test "bug201: uint64 division keeps all bits" {
	assert THIRD201 == 6148914691236517205;
}

test "bug201: signed boundary literals keep their value" {
	assert LOWEST201 + 1 == -2147483647;
	assert NEGATIVE201 + 9223372036854775807 == 0;
}
