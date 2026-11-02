// @stdout: false 7 true 9
// @stdout: true 3 4 false 7
// @exit: 0
struct Failure {
	code: uint64;
}

struct Key {
	bytes: uint8[4];
}

function bad(): Result<int32, Failure> {
	return Result.err({ code: 7 });
}

function keyed(last: uint8): Result<Key, Failure> {
	return Result.ok({ bytes: [1, 2, 3, last] });
}

const results: Result<int32, Failure>[] = [bad(), Result.ok(9)];
const first = results[0];
const second = results[1];
if (!first.ok && second.ok) {
	console.log(first.ok, first.error.code, second.ok, second.value);
}

const keys: Result<Key, Failure>[] = [keyed(4), bad2()];
function bad2(): Result<Key, Failure> {
	return Result.err({ code: 7 });
}
const k = keys[0];
const m = keys[1];
if (k.ok && !m.ok) {
	console.log(k.ok, k.value.bytes[2], k.value.bytes[3], m.ok, m.error.code);
}
