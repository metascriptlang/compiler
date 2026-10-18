// Parity program — a top-level await in a dependency of a module reached only through
// import(): a synchronous sibling dependency runs while the dependency awaits, the module
// runs its body only after the dependency finished, and the import resolves after both.
//
// @stdout: start
// @stdout: dep start
// @stdout: side body
// @stdout: dep end
// @stdout: lazy body 4 1
// @stdout: got 9

async function run(): Promise<void> {
	const m = await import("./lazy");
	console.log(`got ${m.v}`);
}

console.log("start");
run();
