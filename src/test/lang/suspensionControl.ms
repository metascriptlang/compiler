async function chainLeaf(): Promise<int32> { return 42; }

async function chainMiddle(): Promise<int32> { return (await chainLeaf()) + 1; }

async function tryFinallyAwait(): Promise<int32> {
	let acc = 0;
	try {
		const w = spawn(() => 1);
		const n = await w;
		acc = acc + n;
	} finally {
		acc = acc + 7;
	}
	return acc;
}

async function tryCatchFinallyAwait(): Promise<int32> {
	let acc = 0;
	try {
		const w = spawn(() => 2);
		const n = await w;
		acc = acc + n;
	} catch (e) {
		acc = acc + 100;
	} finally {
		acc = acc + 30;
	}
	return acc;
}

async function finallyRunsOnThrow(): Promise<int32> {
	let acc = 0;
	try {
		const w = spawn(() => 4);
		const n = await w;
		acc = acc + n;
		throw "boom";
	} catch (e) {
		acc = acc + 200;
	} finally {
		acc = acc + 1000;
	}
	return acc;
}

async function loopBreakCrossesFinally(): Promise<int32> {
	let acc = 0;
	while (true) {
		try {
			const w = spawn(() => 3);
			const n = await w;
			acc = acc + n;
			break;
		} finally {
			acc = acc + 50;
		}
	}
	return acc;
}

function capturedDispatchLoop(k: int32): () => string {
	let s: int32 = 0;
	const f = (): string => {
		while (true) {
			if (s == 0) {
				switch (k) {
					case 1:
						s = 1;
						break;
					default:
						s = 2;
						break;
				}
			} else {
				return s.toString();
			}
		}
	};
	return f;
}

function* capturedDispatchGen(k: int32): Iterator<string> {
	switch (k) {
		case 1:
			yield "one";
			break;
		default:
			yield "other";
	}
}

async function fulfilledValueWork(x: int32): Promise<int32> {
	return x * 2;
}

let fulfilledValueSeen: int32 = 0;

function fulfilledValueRecord(v: int32): void {
	fulfilledValueSeen = v;
}

function spawnBindingUseIt(p: Promise<int32>): int32 {
	return await p;
}

function spawnBindingPassed(): int32 {
	const w = spawn((): int32 => 1);
	return spawnBindingUseIt(w);
}

async function spawnBindingInAsync(): Promise<int32> {
	const w = spawn((): int32 => 4);
	const n = await w;
	return n + 1;
}

function spawnBindingAwaitOnly(): int32 {
	const h = spawn((): int32 => 2);
	const g = (): int32 => 3;
	const v = await h;
	return v + g();
}

test "suspensionControl: await chains deliver the value to their consuming test" {
	assert await chainMiddle() == 43;
	assert await chainLeaf() == 42;
}

test "suspensionControl: finally runs after an awaited try body" {
	const acc = await tryFinallyAwait();
	assert acc == 8;
}

test "suspensionControl: try/catch/finally with an await takes the normal path" {
	const acc = await tryCatchFinallyAwait();
	assert acc == 32;
}

test "suspensionControl: finally runs when the try body throws after an await" {
	const acc = await finallyRunsOnThrow();
	assert acc == 1204;
}

test "suspensionControl: a break out of the loop still runs the finally" {
	const acc = await loopBreakCrossesFinally();
	assert acc == 53;
}

test "suspensionControl: a closure switching on a captured variable" {
	assert capturedDispatchLoop(1)() == "1";
	assert capturedDispatchLoop(7)() == "2";
}

test "suspensionControl: a generator switching on its parameter" {
	let out: string = "";
	for (const v of capturedDispatchGen(1)) out = out + v;
	for (const v of capturedDispatchGen(3)) out = out + v;
	assert out == "oneother";
}

test "suspensionControl: then with an arrow receives the fulfilled value" {
	fulfilledValueSeen = 0;
	const w = fulfilledValueWork(5);
	const p = w.then((v: int32): void => { fulfilledValueSeen = v; });
	await p;
	assert fulfilledValueSeen == 10;
}

test "suspensionControl: then with a named function receives the fulfilled value" {
	fulfilledValueSeen = 0;
	const w = fulfilledValueWork(7);
	await w.then(fulfilledValueRecord);
	assert fulfilledValueSeen == 14;
}

test "suspensionControl: a spawn handle passed to a function keeps its binding" {
	assert spawnBindingPassed() == 1;
}

test "suspensionControl: a spawn handle awaited in an async function keeps its binding" {
	assert await spawnBindingInAsync() == 5;
}

test "suspensionControl: a spawn handle awaited in its own function still works across a nested closure" {
	assert spawnBindingAwaitOnly() == 5;
}
