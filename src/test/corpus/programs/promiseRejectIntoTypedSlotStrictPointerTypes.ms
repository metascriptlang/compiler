// @stdout: assign|ret|await|then|resolve 7|done

@passC("-Werror=incompatible-pointer-types");

function failing(): Promise<string> { return Promise.reject(new Error("ret")); }

async function run(): Promise<void> {
	let log = "";
	const p: Promise<int32> = Promise.reject(new Error("assign"));
	try { log += `${await p}`; } catch (e) { log += `${e.message}|`; }
	try { log += await failing(); } catch (e) { log += `${e.message}|`; }
	try { log += `${await Promise.reject(new Error("await"))}`; } catch (e) { log += `${e.message}|`; }
	await Promise.reject(new Error("then")).catch((e: Error): void => { log += `${e.message}|`; });
	const r: Promise<int32> = Promise.resolve(7);
	log += `resolve ${await r}|`;
	console.log(log + "done");
}
run();
