let saved: int32 = 0;

async function save(k: int32): Promise<void> {
	saved = saved + k;
}

async function tick(x: int32): Promise<int32> {
	return x;
}

async function awaitInDo(): Promise<void> {
	let i: int32 = 0;
	do {
		await save(1);
		i++;
	} while (i < 3);
}

async function awaitInSwitch(k: int32): Promise<int32> {
	let r: int32 = 0;
	switch (k) {
		case 1:
			r = await tick(11);
			break;
		default:
			r = 0;
	}
	return r;
}

async function returnInDo(n: int32): Promise<int32> {
	let i: int32 = 0;
	do {
		if (i == n) return i * 10;
		i++;
	} while (i < 5);
	return -1;
}

async function returnInSwitch(k: int32): Promise<int32> {
	const base = await tick(100);
	switch (k) {
		case 1:
			return base + 1;
		case 2:
			return base + 2;
		default:
			break;
	}
	return base;
}

function closureInDo(): Promise<int32> {
	let i: int32 = 0;
	let f: () => Promise<int32> = async (): Promise<int32> => 0;
	do {
		f = async (): Promise<int32> => { const v = await tick(7); return v + 1; };
		i++;
	} while (i < 1);
	return f();
}

async function closureInSwitch(k: int32): Promise<int32> {
	let total: int32 = 0;
	switch (k) {
		case 1: {
			const f = async (): Promise<int32> => { const v = await tick(5); return v + 1; };
			total = await f();
			break;
		}
		default:
			total = 0;
	}
	return total;
}

let log = "";

async function returnThroughAwaitingFinally(): Promise<int32> {
	try {
		const a = await tick(1);
		if (a == 1) return 5;
	} finally {
		const b = await tick(2);
		log = log + "fin" + b.toString();
	}
	return 0;
}

async function main(): Promise<void> {
	await awaitInDo();
	console.log(saved);
	console.log(await awaitInSwitch(1));
	console.log(await awaitInSwitch(2));
	console.log(await returnInDo(2));
	console.log(await returnInDo(9));
	console.log(await returnInSwitch(2));
	console.log(await returnInSwitch(7));
	console.log(await closureInDo());
	console.log(await closureInSwitch(1));
	console.log(await returnThroughAwaitingFinally());
	console.log(log);
}

await main();
