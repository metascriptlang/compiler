// @stdout: async caught bad|finally caught bad|gen 1 caught late|loop 0 bad 1 bad
// note: the state machine stores the caught exception into its env slot through a binding of the slot's own C type, so the C compiler accepts it under -Werror=incompatible-pointer-types, the default of emscripten's clang (before, it stored an msException* into an Error* field and `--os=emcc` refused it); async catch-only and catch+finally, a generator, a catch in a loop.

@passC("-Werror=incompatible-pointer-types");

async function fail(): Promise<int32> { throw new Error("bad"); }

async function catchOnly(): Promise<string> {
	try { return `${await fail()}`; } catch (e) { return `caught ${e.message}`; }
}
async function catchFinally(): Promise<string> {
	let r = "";
	try { r = `${await fail()}`; } catch (e) { r = `caught ${e.message}`; } finally { r = `finally ${r}`; }
	return r;
}
function* gen(): Iterator<string> {
	try { yield "1"; throw new Error("late"); } catch (e) { yield `caught ${e.message}`; }
}
async function inLoop(): Promise<string> {
	let r = "";
	for (let i = 0; i < 2; i += 1) {
		try { await fail(); } catch (e) { r = `${r} ${i} ${e.message}`; }
	}
	return r;
}

async function main(): Promise<void> {
	const a = await catchOnly();
	const f = await catchFinally();
	let g = "";
	for (const v of gen()) g = `${g} ${v}`;
	const l = await inLoop();
	console.log(`async ${a}|${f}|gen${g}|loop${l}`);
}
main();
