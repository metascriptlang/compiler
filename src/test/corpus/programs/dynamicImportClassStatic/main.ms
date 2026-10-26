// @stdout: start
// @stdout: lib before
// @stdout: static K
// @stdout: lib after
// @stdout: 1
//
// A static field read through the namespace import() returns is the class's field, and
// its initializer runs at its place in the module body, at the import: not at startup.

async function run(): Promise<void> {
	const m = await import("./lib");
	console.log(`${m.K.v}`);
}

console.log("start");
run();
