// @xfail(raiser): the Raiser VM joins the awaited branches in another order (logs 'f1;f2;f2;' where C logs 'f1;f1;f2;')
async function work(x: int32): Promise<int32> {
	return x * 2;
}

let log: string = "";

async function ifTail(c: boolean): Promise<void> {
	if (c) {
		await work(1);
	}
	log = log + "if" + (c ? "T" : "F") + ";";
}

async function loopTail(): Promise<int32> {
	let i: int32 = 0;
	let s: int32 = 0;
	while (i < 3) {
		i++;
		s = s + i;
		await work(i);
	}
	return s;
}

async function matchTail(k: int32): Promise<void> {
	match (k) {
		1 => { await work(10); },
		_ => { await work(100); },
	}
	log = log + "m" + k.toString() + ";";
}

async function branchValues(c: boolean): Promise<int32> {
	let r: int32 = 0;
	if (c) {
		const a = await work(1);
		r = a;
	} else {
		const b = await work(5);
		r = b;
	}
	return r;
}

async function jumpsThroughFinally(): Promise<int32> {
	let i: int32 = 0;
	while (i < 5) {
		try {
			const v = await work(i);
			if (v >= 4) break;
			if (v == 0) {
				i++;
				continue;
			}
		} finally {
			log = log + "f" + i.toString() + ";";
		}
		i++;
	}
	return i;
}

function expectInt(label: string, actual: int32, expected: int32): void {
	if (actual != expected) throw new Error(label + " expected=" + expected.toString() + " actual=" + actual.toString());
}

function expectStr(label: string, actual: string, expected: string): void {
	if (actual != expected) throw new Error(label + " expected=" + expected + " actual=" + actual);
}

async function main(): Promise<void> {
	await ifTail(false);
	await ifTail(true);
	const s = await loopTail();
	await matchTail(1);
	await matchTail(2);
	const x = await branchValues(true);
	const y = await branchValues(false);
	const j = await jumpsThroughFinally();
	expectInt("loopTail", s, 6);
	expectInt("branchTrue", x, 2);
	expectInt("branchFalse", y, 10);
	expectInt("jumps", j, 2);
	expectStr("log", log, "ifF;ifT;m1;m2;f1;f1;f2;");
	console.log("loopTail=" + s.toString() + " branches=" + x.toString() + "," + y.toString() + " jumps=" + j.toString());
	console.log("log: " + log);
}

await main();
