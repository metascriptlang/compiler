// Parity program — a class, an enum and a generic function read through the namespace
// import() returns name the module's declarations, and none of them loads the module
// before the import: a static method, a construction, an enum member and two generic
// instances, beside a variable read the same way.
//
// @stdout: start
// @stdout: lib body
// @stdout: 8 5 green 2 1 3

async function run(): Promise<void> {
	const m = await import("./lib");
	const words = m.pair("ab");
	const nums = m.pair(1);
	console.log(`${m.K.twice(4)} ${new m.K().plus(1)} ${m.label(m.Color.Green)} ${words.length} ${nums[1]} ${m.counter}`);
}

console.log("start");
run();
