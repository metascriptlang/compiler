// Parity program — the catch binding of an async function is carried across the
// await state split as `$curExc`, and only references to that binding move with
// it: a same-named declaration inside the handler keeps its own value.
//
// @stdout: inner|boom
// @exit: 0

async function fail(): Promise<int32> {
	throw new Error("boom");
}

async function run(): Promise<void> {
	let seen = "";
	try {
		await fail();
	} catch (e) {
		{
			const e = "inner";
			seen = e;
		}
		console.log(seen + "|" + e.message);
	}
}

await run();
