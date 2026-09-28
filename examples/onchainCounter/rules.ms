export enum CounterError {
	ZeroAmount,
	LimitExceeded,
}

export struct Counter {
	value: uint64;
}

export function increment(
	this ref counter: Counter,
	amount: uint64,
): Result<uint64, CounterError> {
	if (amount == 0) { return Result.err(CounterError.ZeroAmount); }
	const limit: uint64 = 1000000;
	if (amount > limit || counter.value > limit - amount) {
		return Result.err(CounterError.LimitExceeded);
	}
	counter.value += amount;
	return Result.ok(counter.value);
}

test "increment commits the exact bounded value" {
	let counter: Counter = { value: 999995 };
	const result = counter.increment(5);
	assert result.ok;
	if (result.ok) { assert result.value == 1000000; }
	assert counter.value == 1000000;
}

test "rejected increment leaves the counter unchanged" {
	let counter: Counter = { value: 7 };
	const empty = counter.increment(0);
	assert !empty.ok;
	const tooLarge = counter.increment(1000000);
	assert !tooLarge.ok;
	const wrapping: uint64 = 0xffffffffffffffff;
	const overflow = counter.increment(wrapping);
	assert !overflow.ok;
	assert counter.value == 7;
}
