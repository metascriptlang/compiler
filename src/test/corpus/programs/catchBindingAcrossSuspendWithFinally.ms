// @stdout: async 2 2 2 2 3 3 3 rejected bad gen 1 2 3 4 catchless nested2 4 gen2 1 2 3 l2
// note: a catch binding read in a state machine whose try also has a finally reads the caught exception (C rejected the read as an undeclared identifier); a raise leaving a finally reaches the enclosing catch, and a catch-less finally re-raises (C swallowed both); async and generator, suspend in try, catch or finally, nested one and two levels deep.

async function fail(): Promise<int32> { throw new Error("bad"); }
async function ok(): Promise<int32> { return 5; }

async function returnAwaitInTry(): Promise<int32> {
	try { return await fail(); } catch (e) { console.log(`returnAwaitInTry caught ${e.message}`); return 2; } finally { console.log("returnAwaitInTry finally"); }
}
async function constAwaitInTry(): Promise<int32> {
	try { const x = await fail(); console.log(`unreached ${x}`); return 1; } catch (e) { console.log(`constAwaitInTry caught ${e.message}`); return 2; } finally { console.log("constAwaitInTry finally"); }
}
async function awaitInCatch(): Promise<int32> {
	try { throw new Error("sync"); } catch (e) { const v = await ok(); console.log(`awaitInCatch caught ${e.message} ${v}`); return 2; } finally { console.log("awaitInCatch finally"); }
}
async function awaitInFinally(): Promise<int32> {
	try { throw new Error("sync"); } catch (e) { console.log(`awaitInFinally caught ${e.message}`); return 2; } finally { const v = await ok(); console.log(`awaitInFinally finally ${v}`); }
}
async function nested(): Promise<int32> {
	try {
		try { return await fail(); } catch (e) { console.log(`nested inner ${e.message}`); throw new Error("again"); } finally { console.log("nested inner finally"); }
	} catch (e2) { console.log(`nested outer ${e2.message}`); return 3; } finally { console.log("nested outer finally"); }
}

async function rethrowThroughInnerFinally(): Promise<int32> {
	try {
		try { return await fail(); } catch (e) { console.log(`rethrow inner ${e.message}`); throw new Error("again"); } finally { console.log("rethrow inner finally"); }
	} catch (e2) { console.log("rethrow outer"); return 3; }
}
async function catchlessFinallyInCatch(): Promise<int32> {
	try {
		try { await fail(); } finally { console.log("catchless inner finally"); }
		console.log("catchless unreached");
	} catch (e) { console.log(`catchless outer ${e.message}`); return 3; } finally { console.log("catchless outer finally"); }
	return 9;
}
async function catchlessFinallyRejects(): Promise<int32> {
	try { const x = await fail(); console.log(`unreached ${x}`); } finally { console.log("rejects finally"); }
	return 9;
}

async function nested2(): Promise<int32> {
	try {
		try {
			try { return await fail(); } catch (e) { await ok(); throw new Error("l1"); } finally { console.log("nested2 level0 finally"); }
		} catch (e) { console.log(`nested2 level1 ${e.message}`); await ok(); throw new Error("l2"); } finally { console.log("nested2 level1 finally"); }
	} catch (e) { console.log(`nested2 level2 ${e.message}`); return 4; } finally { await ok(); console.log("nested2 level2 finally"); }
}

function* gen2(): Iterator<int32> {
	try {
		try {
			try { yield 1; throw new Error("l0"); } catch (e) { yield 2; throw new Error("l1"); } finally { console.log("gen2 level0 finally"); }
		} catch (e) { console.log(`gen2 level1 ${e.message}`); yield 3; throw new Error("l2"); } finally { console.log("gen2 level1 finally"); }
	} finally { console.log("gen2 level2 finally"); }
}

function* gen(): Iterator<int32> {
	try { yield 1; throw new Error("bad"); } catch (e) { console.log(`gen caught ${e.message}`); yield 2; } finally { console.log("gen finally"); }
	try { yield 3; throw new Error("late"); } catch (e) { yield 4; console.log(`gen caught after yield ${e.message}`); } finally { console.log("gen finally 2"); }
	try { yield 5; throw new Error("catchless"); } finally { console.log("gen catchless finally"); }
}

async function main(): Promise<void> {
	const a = await returnAwaitInTry();
	const b = await constAwaitInTry();
	const c = await awaitInCatch();
	const d = await awaitInFinally();
	const n = await nested();
	const r = await rethrowThroughInnerFinally();
	const cl = await catchlessFinallyInCatch();
	let rej = "resolved";
	try { rej = `resolved ${await catchlessFinallyRejects()}`; } catch (e) { rej = `rejected ${e.message}`; }
	let g = "";
	try { for (const v of gen()) { if (v < 5) g = g + ` ${v}`; } } catch (e) { g = g + ` ${e.message}`; }
	const n2 = await nested2();
	let g2 = "";
	try { for (const v of gen2()) g2 = g2 + ` ${v}`; } catch (e) { g2 = g2 + ` ${e.message}`; }
	console.log(`async ${a} ${b} ${c} ${d} ${n} ${r} ${cl} ${rej} gen${g} nested2 ${n2} gen2${g2}`);
}
main();
