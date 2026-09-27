// bug464 — a closure made inside an async function or a generator wrote to a copy
//
// Symptom:    on C, `const add = (k) => { count += k; }` after an await left
//             count unchanged (0 instead of 7); the same in a generator after a
//             yield, in a `.then` callback, and for every closure made in a loop
//             of such a function (`total` stayed 0).
// Root cause: src/transform/lowering/lambdaLifting.ms treated the state
//             machine's dispatcher `while (true)` as a user loop and gave every
//             closure inside it a private env holding copies of its captures.
//             src/transform/lowering/generatorLower.ms and asyncBridge.ms also
//             kept every local in the machine's env, so a closure stored in a
//             local formed an env -> closure -> env cycle once it shared.
// Fix:        only a loop body that declares a binding a closure reads gets a
//             per-iteration env; the dispatcher declares none, so its closures
//             share the machine's env. A local touched by one state only stays
//             a local of that state's block. A binding of a loop body split at
//             an await is still copied into the closure (NIM-REF TR-11).
//
// Guarded end-to-end by corpus/programs/928-stateMachineClosureShares.ms.

type B464Get = () => int32;

async function b464Work(x: int32): Promise<int32> {
	return x * 2;
}

async function b464AfterAwait(): Promise<int32> {
	let count: int32 = 0;
	const v = await b464Work(1);
	const add = (k: int32): void => { count = count + k; };
	add(v);
	add(5);
	return count;
}

async function b464LoopOfAsync(): Promise<string> {
	let total: int32 = 0;
	const w = await b464Work(5);
	const fns: (() => void)[] = [];
	for (let i: int32 = 0; i < 3; i++) {
		let j: int32 = i * 10;
		fns.push((): void => { total += i + j + w; });
		j = j + 1;
	}
	for (const f of fns) f();
	return `${total}`;
}

async function b464AwaitInLoop(): Promise<string> {
	let total: int32 = 0;
	const fns: (() => void)[] = [];
	const reads: B464Get[] = [];
	for (let i: int32 = 0; i < 3; i++) {
		fns.push((): void => { total += i; });
		const w = await b464Work(i);
		reads.push((): int32 => w);
	}
	for (const f of fns) f();
	let s = `${total}`;
	for (const r of reads) s = s + ` ${r()}`;
	return s;
}

async function b464Then(): Promise<int32> {
	let local: int32 = 0;
	const p = b464Work(5).then((v: int32): void => { local = v; });
	await p;
	return local;
}

function* b464Gen(): Iterator<int32> {
	let seen: int32 = 0;
	yield 1;
	const bump = (): void => { seen = seen + 1; };
	bump();
	bump();
	yield seen;
}

function* b464GenLoop(): Iterator<int32> {
	const fs: B464Get[] = [];
	let base: int32 = 0;
	for (let i: int32 = 0; i < 3; i++) {
		let j: int32 = i * 10;
		fs.push((): int32 => base + i + j);
		j = j + 1;
	}
	yield fs.length;
	base = 100;
	for (let k: int32 = 0; k < fs.length; k++) yield fs[k]();
}

test "bug464: a closure made after an await writes the function's variable" {
	assert await b464AfterAwait() == 7;
}

test "bug464: closures of a loop in an async function share its variables" {
	assert await b464LoopOfAsync() == "66";
}

test "bug464: closures of a loop that awaits share the function's variables" {
	assert await b464AwaitInLoop() == "3 0 2 4";
}

test "bug464: a then callback writes the awaiting function's variable" {
	assert await b464Then() == 10;
}

test "bug464: a closure made after a yield writes the generator's variable" {
	let s = "";
	for (const v of b464Gen()) s = s + `${v} `;
	assert s == "1 2 ";
}

test "bug464: closures of a loop in a generator own their iteration and share the rest" {
	let s = "";
	for (const v of b464GenLoop()) s = s + `${v} `;
	assert s == "3 101 112 123 ";
}
