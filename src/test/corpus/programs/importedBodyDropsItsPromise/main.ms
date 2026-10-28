// @stdout: start
// @stdout: side body
// @stdout: tick done
// @stdout: got 7
// note: a module reached through import() whose body calls an async function and drops the promise releases that promise when its body ends, as any routine releases its temporaries.

async function run(): Promise<void> {
	const m = await import("./side");
	await sleepAsync(10);
	console.log(`got ${m.v}`);
}

console.log("start");
run();
