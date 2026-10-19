// @xfail(raiser): an async call runs inline on Raiser, so a promise handed to settle() before its await raises at the call instead of rejecting (inbox 2026-10-15-raiser-async-call-runs-inline)
// @stdout: reraise 3 3 rejected bad rejected x gen 1 catchless
// note: in a state machine, a raise that leaves a finally reaches the enclosing catch, and a catch-less try/finally re-raises instead of swallowing (C dropped the exception and ran on with the next statement).

async function fail(): Promise<int32> { throw new Error("bad"); }
async function ok(): Promise<int32> { return 5; }

async function rethrowThroughInnerFinally(): Promise<int32> {
	try {
		try { return await fail(); } catch (e) { console.log("inner caught"); throw new Error("again"); } finally { console.log("inner finally"); }
	} catch (e2) { console.log("outer caught"); return 3; }
}
async function catchlessInsideCatch(): Promise<int32> {
	try {
		try { await fail(); } finally { console.log("catchless finally"); }
		console.log("unreached after catchless");
	} catch (e) { console.log("outer caught catchless"); return 3; }
	return 9;
}
async function catchlessAwaitRaises(): Promise<int32> {
	try { const x = await fail(); console.log(`unreached ${x}`); } finally { console.log("finally after failed await"); }
	return 9;
}
async function catchlessThrowAfterAwait(): Promise<int32> {
	try { await ok(); throw new Error("x"); } finally { console.log("finally after throw"); }
	return 9;
}
async function settle(p: Promise<int32>): Promise<string> {
	try { return `resolved ${await p}`; } catch (e) { return `rejected ${e.message}`; }
}

function* gen(): Iterator<int32> {
	try { yield 1; throw new Error("catchless"); } finally { console.log("gen finally"); }
	yield 2;
}

async function main(): Promise<void> {
	const r = await rethrowThroughInnerFinally();
	const c = await catchlessInsideCatch();
	const a = await settle(catchlessAwaitRaises());
	const t = await settle(catchlessThrowAfterAwait());
	let g = "";
	try { for (const v of gen()) g = g + ` ${v}`; } catch (e) { g = g + ` ${e.message}`; }
	console.log(`reraise ${r} ${c} ${a} ${t} gen${g}`);
}
main();
