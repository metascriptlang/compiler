// @stdout: generator return 10
// @stdout: generator throw second x5
// @stdout: async throw second x5
// @stdout: async return 0 x5
// note: a `finally` in a generator or an async function that throws, or returns, while an exception is in flight replaces that exception, and the replaced one is released. Before the fix the frame held it in an untyped slot that nothing freed, so each call leaked one `Error`; the san lane's ledger balances only when every one of them is destroyed.

function* lostByReturn(): Iterator<int32> {
	try {
		yield 1;
		throw new Error("lost");
	} finally {
		return;
	}
}

function* replacedByThrow(): Iterator<int32> {
	try {
		yield 1;
		throw new Error("first");
	} finally {
		throw new Error("second");
	}
}

async function asyncReplacedByThrow(): Promise<int32> {
	try {
		await Promise.resolve(0);
		throw new Error("first");
	} finally {
		throw new Error("second");
	}
}

async function asyncLostByReturn(): Promise<int32> {
	try {
		await Promise.resolve(0);
		throw new Error("lost");
	} finally {
		return 0;
	}
}

async function main(): Promise<void> {
	let sum: int32 = 0;
	let genCaught = "";
	let genCount: int32 = 0;
	for (let i: int32 = 0; i < 5; i++) {
		for (const v of lostByReturn()) sum += v * 2;
		try {
			for (const v of replacedByThrow()) sum += 0 * v;
		} catch (e) {
			genCaught = e.message;
			genCount++;
		}
	}
	console.log(`generator return ${sum}`);
	console.log(`generator throw ${genCaught} x${genCount}`);

	let asyncCaught = "";
	let asyncCount: int32 = 0;
	let returned: int32 = -1;
	let returnCount: int32 = 0;
	for (let i: int32 = 0; i < 5; i++) {
		try {
			await asyncReplacedByThrow();
		} catch (e) {
			asyncCaught = e.message;
			asyncCount++;
		}
		returned = await asyncLostByReturn();
		returnCount++;
	}
	console.log(`async throw ${asyncCaught} x${asyncCount}`);
	console.log(`async return ${returned} x${returnCount}`);
}

await main();
