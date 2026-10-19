// @stdout: start
// @stdout: sync end
// @stdout: lazy body
// @stdout: got 7

async function run(): Promise<void> {
	const m = await import("../shared/lazy");
	console.log(`got ${m.v}`);
}

console.log("start");
run();
console.log("sync end");
