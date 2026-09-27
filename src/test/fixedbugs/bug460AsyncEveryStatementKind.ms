// bug460 — an async function whose await or return sat only inside a
// do-while or a switch lost it on C
//
// Symptom:    on C, `do { await save(1); i++; } while (i < 3);` never ran
//             save() and the function completed at once; a return inside a
//             do-while or a switch case returned its raw value instead of
//             completing the future (C did not compile); an async closure
//             declared inside a do-while or a switch case was never lowered.
//             JS was correct.
// Root cause: src/transform/lowering/asyncBridge.ms decided "no await here"
//             and rewrote returns with walkers that stopped at do-while and
//             switch, and asyncDesugar.ms / asyncBridge.ms looked for async
//             closures with walkers that stopped there too.
// Fix:        every one of those walks visits every statement and
//             expression, stopping only at nested routines.
//
// Guarded end-to-end by corpus/programs/924-asyncStatementKinds.ms.

let b460Saved: int32 = 0;

async function b460Save(k: int32): Promise<void> {
	b460Saved = b460Saved + k;
}

async function b460Tick(x: int32): Promise<int32> {
	return x;
}

async function b460AwaitInDo(): Promise<void> {
	let i: int32 = 0;
	do {
		await b460Save(1);
		i++;
	} while (i < 3);
}

async function b460AwaitInSwitch(k: int32): Promise<int32> {
	let r: int32 = 0;
	switch (k) {
		case 1:
			r = await b460Tick(11);
			break;
		default:
			r = 0;
	}
	return r;
}

async function b460ReturnInDo(n: int32): Promise<int32> {
	let i: int32 = 0;
	do {
		if (i == n) return i * 10;
		i++;
	} while (i < 5);
	return -1;
}

async function b460ReturnInSwitch(k: int32): Promise<int32> {
	const base = await b460Tick(100);
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

function b460ClosureInDo(): Promise<int32> {
	let i: int32 = 0;
	let f: () => Promise<int32> = async (): Promise<int32> => 0;
	do {
		f = async (): Promise<int32> => { const v = await b460Tick(7); return v + 1; };
		i++;
	} while (i < 1);
	return f();
}

async function b460ReturnThroughAwaitingFinally(log: string[]): Promise<int32> {
	try {
		const a = await b460Tick(1);
		if (a == 1) return 5;
	} finally {
		const b = await b460Tick(2);
		log.push("fin" + b.toString());
	}
	return 0;
}

test "bug460: an await only inside a do-while runs on every pass" {
	b460Saved = 0;
	await b460AwaitInDo();
	assert b460Saved == 3;
}

test "bug460: an await only inside a switch case" {
	assert await b460AwaitInSwitch(1) == 11;
	assert await b460AwaitInSwitch(2) == 0;
}

test "bug460: a return inside a do-while or a switch completes the future" {
	assert await b460ReturnInDo(2) == 20;
	assert await b460ReturnInDo(9) == -1;
	assert await b460ReturnInSwitch(2) == 102;
	assert await b460ReturnInSwitch(7) == 100;
}

test "bug460: an async closure declared inside a do-while is lowered" {
	assert await b460ClosureInDo() == 8;
}

test "bug460: a return inside a try runs an awaiting finally first" {
	const log: string[] = [];
	assert await b460ReturnThroughAwaitingFinally(log) == 5;
	assert log.length == 1;
	assert log[0] == "fin2";
}
