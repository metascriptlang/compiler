class Counter {
	count: int32 = 0;
}

export function work(n: int32): int32 {
	const counter = new Counter();
	counter.count += n;
	return counter.count;
}
