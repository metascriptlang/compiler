// bug203 — a typed `for` initializer loses its annotation
//
// Symptom:    `for (let i: uint64 = 2147483646; i < 2147483650; i++)` ran an
//             int32 counter: C panicked on signed overflow at 2^31, and JS
//             emitted a Number that threw `Cannot mix BigInt` at a uint64 formal.
// Root cause: parseForStmt (src/parser/statements/control.ms) skipped the type
//             and built the VariableDecl with an empty declType.
// Fix:        capture the annotation as parseVariableDecl does.

struct Holder203 { epoch: uint64; }

function advancedTo203(this holder: Holder203, epoch: uint64): Holder203 {
	return { epoch: holder.epoch + epoch };
}

test "bug203: uint64 counter crosses 2^31" {
	let last: uint64 = 0;
	for (let big: uint64 = 2147483646; big < 2147483650; big++) {
		last = big;
	}
	assert last == 2147483649;
}

test "bug203: int64 counter crosses 2^31" {
	let steps: int32 = 0;
	let last: int64 = 0;
	for (let wide: int64 = 2147483645; wide <= 2147483650; wide++) {
		last = wide;
		steps++;
	}
	assert last == 2147483650;
	assert steps == 6;
}

test "bug203: uint64 counter reaches a method-syntax uint64 formal" {
	let holder: Holder203 = { epoch: 0 };
	for (let epoch: uint64 = 1; epoch <= 3; epoch++) {
		holder = holder.advancedTo203(epoch);
	}
	assert holder.epoch == 6;
}
