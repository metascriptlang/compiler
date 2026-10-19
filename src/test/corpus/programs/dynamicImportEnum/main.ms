// Parity program — reading an enum member through the namespace import() returns does
// not load the module early, from the entry or from a module that is itself loaded
// through import(): each body runs at its own import.
//
// @stdout: start
// @stdout: lazy body
// @stdout: big small
// @stdout: nested body
// @stdout: sizes body
// @stdout: light dark

async function run(): Promise<void> {
	const m = await import("./lazy");
	console.log(`${m.label(m.Size.Big)} ${m.label(m.Size.Small)}`);
	const n = await import("./nested");
	console.log(await n.describe());
}

console.log("start");
run();
