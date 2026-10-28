// Parity program — an async `defer` closes after the `return` value is computed,
// also when an await comes before the return: a field read, a call, a struct
// field, a nested try/finally, and two defers closing last-first.
//
// @stdout: plain=true noAwait=true await=true local=true
// @stdout: call=true struct=7 nested=true,fin2,fin1 two=1,close2,close1
// @exit: 0

class Handle {
	open: boolean = true;
	n: int32 = 7;
}

function close(this h: Handle): void {
	h.open = false;
	h.n = 0;
}

function isOpen(h: Handle): boolean {
	return h.open;
}

const log: string[] = [];

function readSync(h: Handle): boolean {
	defer h.close();
	return h.open;
}

async function readNoAwait(h: Handle): Promise<boolean> {
	defer h.close();
	return h.open;
}

async function readAwait(h: Handle): Promise<boolean> {
	defer h.close();
	await sleepAsync(1);
	return h.open;
}

async function readLocal(h: Handle): Promise<boolean> {
	defer h.close();
	await sleepAsync(1);
	const seen = h.open;
	return seen;
}

async function readCall(h: Handle): Promise<boolean> {
	defer h.close();
	await sleepAsync(1);
	return isOpen(h);
}

async function readField(h: Handle): Promise<int32> {
	defer h.close();
	await sleepAsync(1);
	return h.n;
}

async function readNested(h: Handle): Promise<boolean> {
	defer log.push("fin1");
	try {
		defer log.push("fin2");
		await sleepAsync(1);
		return h.open;
	} finally {
		h.close();
	}
}

async function readTwo(h: Handle): Promise<int32> {
	defer log.push("close1");
	defer log.push("close2");
	await sleepAsync(1);
	return log.length + 1;
}

async function main(): Promise<void> {
	const plain = String(readSync(new Handle()));
	const noAwait = String(await readNoAwait(new Handle()));
	const aw = String(await readAwait(new Handle()));
	const local = String(await readLocal(new Handle()));
	console.log("plain=" + plain + " noAwait=" + noAwait + " await=" + aw + " local=" + local);
	const call = String(await readCall(new Handle()));
	const field = String(await readField(new Handle()));
	const nested = String(await readNested(new Handle()));
	const nestedLog = log.join(",");
	log.length = 0;
	const two = String(await readTwo(new Handle()));
	console.log("call=" + call + " struct=" + field + " nested=" + nested + "," + nestedLog + " two=" + two + "," + log.join(","));
}

await main();
