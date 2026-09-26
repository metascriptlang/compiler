// nim-guard: a loop iteration's env links to the env around it only when a closure made in the
// iteration reads past it, so closures that read only their iteration's bindings form no cycle,
// even when the frame's env or an async machine's env holds the array that keeps them.
//
// Nim: lambdalifting.nim:521-540 creates an `up` field on an owner only while walking from a
// closure to the owner of a variable it reads further up; system.nim:2938 closureScope makes the
// iteration such an owner. Measured with the built nim (--mm:arc, 20000 runs): closures reading
// only the closureScope binding, kept in the proc's seq, grow 16 bytes; closures that also read
// the seq grow 4480016 bytes. NIM-REF: TR-11.
//
// reKeptInFrame keeps its closures in an array a sibling closure captures; reKeptDeeper does it
// from an inner loop whose closures read the outer iteration's binding (inner env -> outer env,
// never outer env -> frame); reKeptInMachine keeps them in an async local that spans an await;
// reNotKept drops each closure in its iteration.
//
// RED MEANS an iteration env keeps the env around it alive although no closure made in the
// iteration reads past it — run /trace-nim on lambda lifting's per-iteration env (openLoopEnv).
//
// GUARD-BALANCE dollarEnv_reKeptInFrame_shared_
// GUARD-BALANCE dollarEnv_reKeptInFrame_loop3_
// GUARD-BALANCE dollarEnv_reKeptDeeper_shared_
// GUARD-BALANCE dollarEnv_reKeptDeeper_loop7_
// GUARD-BALANCE dollarEnv_reKeptDeeper_loop8_
// GUARD-BALANCE dollarEnv_reNotKept_shared_
// GUARD-BALANCE dollarEnv_reNotKept_loop12_
// GUARD-BALANCE dollarEnv_reKeptInMachine_shared_
// GUARD-BALANCE dollarEnv_reKeptInMachine_fexpr16_shared_
// GUARD-BALANCE dollarEnv_reKeptInMachine_fexpr16_loop17_
// GUARD-JS

type ReGet = () => int32;

function reKeptInFrame(): int32 {
	const fns: ReGet[] = [];
	const count = (): int32 => fns.length as int32;
	for (const k of [1, 2, 3]) {
		fns.push((): int32 => k);
	}
	let s: int32 = 0;
	for (const f of fns) s = s + f();
	return s + count();
}

function reKeptDeeper(): int32 {
	const fns: ReGet[] = [];
	const count = (): int32 => fns.length as int32;
	for (const a of [10, 20]) {
		for (const b of [1, 2]) {
			fns.push((): int32 => a + b);
		}
	}
	let s: int32 = 0;
	for (const f of fns) s = s + f();
	return s + count();
}

function reNotKept(): int32 {
	const fns: ReGet[] = [];
	const count = (): int32 => fns.length as int32;
	let s: int32 = 0;
	for (const k of [1, 2, 3]) {
		const f = (): int32 => k * 2;
		s = s + f();
	}
	return s + count();
}

async function reWork(x: int32): Promise<int32> {
	return x;
}

async function reKeptInMachine(): Promise<int32> {
	const fns: ReGet[] = [];
	const base = await reWork(100);
	for (const k of [1, 2, 3]) {
		fns.push((): int32 => k);
	}
	let s: int32 = await reWork(base);
	for (const f of fns) s = s + f();
	return s;
}

async function main(): Promise<void> {
	let frame: int32 = 0;
	let deeper: int32 = 0;
	let dropped: int32 = 0;
	let machine: int32 = 0;
	for (let n: int32 = 0; n < 200; n++) {
		frame = frame + reKeptInFrame();
		deeper = deeper + reKeptDeeper();
		dropped = dropped + reNotKept();
		machine = machine + await reKeptInMachine();
	}
	console.log(`frame=${frame} deeper=${deeper} dropped=${dropped} machine=${machine}`);
	if (frame != 1800) throw "GUARD RED: a closure kept in the frame read the wrong iteration, got=" + frame.toString();
	if (deeper != 14000) throw "GUARD RED: a closure made in an inner loop read the wrong iteration, got=" + deeper.toString();
	if (dropped != 2400) throw "GUARD RED: a closure dropped in its iteration read the wrong value, got=" + dropped.toString();
	if (machine != 21200) throw "GUARD RED: a closure kept in an async local read the wrong iteration, got=" + machine.toString();
	console.log("GUARD-OK");
}
await main();
