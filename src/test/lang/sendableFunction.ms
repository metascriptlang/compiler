type Scale = (n: int32) => int32;

function twice(n: int32): int32 { return n * 2; }

const OFFSET: int32 = 10;

async function scaleOnWorkers(h: Sendable<Scale>): Promise<int32[]> {
	const handles: Promise<int32>[] = [];
	for (let i: int32 = 0; i < 3; i += 1) {
		const n = i;
		handles.push(spawn(() => h(n)));
	}
	return await Promise.all(handles);
}

actor Scaler {
	apply(h: Sendable<Scale>, n: int32): int32 { return h(n); }
}

test "sendableFunction: a Sendable function declaration runs inside spawn" {
	const results = await scaleOnWorkers(twice);
	assert results.length == 3 && results[0] == 0 && results[1] == 2 && results[2] == 4;
}

test "sendableFunction: a Sendable closure over a constant runs inside spawn" {
	const results = await scaleOnWorkers((n: int32): int32 => n + OFFSET);
	assert results.length == 3 && results[0] == 10 && results[1] == 11 && results[2] == 12;
}

test "sendableFunction: a Sendable function crosses an actor call" {
	const scaler = new Scaler();
	assert await scaler.apply(twice, 4) == 8;
}

test "sendableFunction: a Sendable function widens to the plain function type" {
	const kept: Sendable<Scale> = twice;
	const plain: Scale = kept;
	assert plain(3) == 6;
}
