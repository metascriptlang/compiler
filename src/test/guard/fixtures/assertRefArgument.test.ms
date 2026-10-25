struct Counter { value: int32; }
struct Owned { values: Vec<int32>; }
enum ProbeError { Failed }

function advance(ref counter: Counter): Result<void, ProbeError> {
	counter.value++;
	return Result.ok(null);
}

function advanceBool(ref counter: Counter): boolean {
	counter.value++;
	return true;
}

function advanceOwned(ref value: Owned): Result<void, ProbeError> {
	value.values[0]++;
	return Result.ok(null);
}

test "rich assert preserves a scalar ref call behind a Result field" {
	let counter: Counter = { value: 0 };
	assert advance(counter).ok;
	assert counter.value == 1;
}

test "rich assert preserves a scalar ref call returning boolean" {
	let counter: Counter = { value: 0 };
	assert advanceBool(counter);
	assert counter.value == 1;
}

test "rich assert preserves an owned vector field ref call" {
	let value: Owned = { values: [0] };
	assert advanceOwned(value).ok;
	assert value.values[0] == 1;
}

test "ordinary ref call followed by assert is a passing control" {
	let counter: Counter = { value: 0 };
	const result = advance(counter);
	assert result.ok;
	assert counter.value == 1;
}

test "loop assert ref call is a passing plain assertion control" {
	for (const initial of [0, 1]) {
		let counter: Counter = { value: initial };
		assert advance(counter).ok;
		assert counter.value == initial + 1;
	}
}

test "owned struct copy itself is a passing control" {
	let original: Owned = { values: [0] };
	let copy = original;
	const result = advanceOwned(copy);
	assert result.ok;
	assert original.values[0] == 0 && copy.values[0] == 1;
}

function addTo(step: int32, ref counter: Counter): int32 {
	counter.value += step;
	return counter.value;
}

test "rich assert preserves a ref call in the second argument inside a comparison" {
	let counter: Counter = { value: 1 };
	assert addTo(2, counter) == 3;
	assert counter.value == 3;
}
