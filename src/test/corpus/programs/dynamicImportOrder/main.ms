// Parity program — a module reached only through import() runs its body once, after the
// importer's synchronous code, and its namespace reads the module's live exports.
//
// @stdout: start
// @stdout: after call
// @stdout: lazy body
// @stdout: hi 1
// @stdout: again 2

async function run(): Promise<void> {
	const p = import("./lazy");
	console.log("after call");
	const m = await p;
	console.log(`${m.hi()} ${m.count}`);
	m.bump();
	const again = await import("./lazy");
	console.log(`again ${again.count}`);
}

console.log("start");
run();
