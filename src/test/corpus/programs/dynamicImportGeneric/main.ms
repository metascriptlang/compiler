// Parity program — a generic export called through the namespace import() returns runs
// the instance its home module defines, one per type argument, and the module still
// runs its body only at the import.
//
// @stdout: start
// @stdout: lazy body
// @stdout: 2 3 ab

async function run(): Promise<void> {
	const m = await import("./lazy");
	const nums = m.pair(3);
	const words = m.pair("ab");
	console.log(`${nums.length} ${nums[0]} ${words[1]}`);
}

console.log("start");
run();
