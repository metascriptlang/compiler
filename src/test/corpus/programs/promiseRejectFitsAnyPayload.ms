// A rejection fits a promise of any payload: assigned to a typed promise, awaited in the return of
// an async function, passed for a promise parameter, bound by a declaration and awaited as a statement.
// @stdout: typed|no count|arg|decl|stmt|done
async function count(): Promise<int32> { return await Promise.reject(new Error("no count")); }
function hold(p: Promise<string>): Promise<string> { return p; }
async function decl(): Promise<int32> {
	const n: int32 = await Promise.reject(new Error("decl"));
	return n;
}
async function stmt(): Promise<void> { await Promise.reject(new Error("stmt")); }

async function run(): Promise<void> {
	let log = "";
	const p: Promise<int32> = Promise.reject(new Error("typed"));
	try { log += `${await p}`; } catch (e) { log += `${e.message}|`; }
	try { log += `${await count()}`; } catch (e) { log += `${e.message}|`; }
	try { log += await hold(Promise.reject(new Error("arg"))); } catch (e) { log += `${e.message}|`; }
	try { log += `${await decl()}`; } catch (e) { log += `${e.message}|`; }
	try { await stmt(); } catch (e) { log += `${e.message}|`; }
	console.log(log + "done");
}
run();
