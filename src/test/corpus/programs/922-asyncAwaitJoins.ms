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

async function main(): Promise<void> {
	await ifTail(false);
	await ifTail(true);
	const s = await loopTail();
	await matchTail(1);
	await matchTail(2);
	const x = await branchValues(true);
	const y = await branchValues(false);
	const j = await jumpsThroughFinally();
	console.log("loopTail=" + s.toString() + " branches=" + x.toString() + "," + y.toString() + " jumps=" + j.toString());
	console.log("log: " + log);
}

await main();
