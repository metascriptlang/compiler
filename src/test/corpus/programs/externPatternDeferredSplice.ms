// @stdout: | 1
// @stdout: 107
// @stdout: 102
when (js) {
	extern function seven(): Promise<int32> from "Promise.resolve(7)";
	extern function later(value: int32): Promise<int32> from "(console.log('pattern runs'), Promise.resolve(0).then(() => #))";
	extern function shifted(value: int32): Promise<int32> from "Promise.resolve(# + 100)";
} else {
	async function seven(): Promise<int32> { return 7; }
	async function later(value: int32): Promise<int32> { console.log("pattern runs"); return value; }
	async function shifted(value: int32): Promise<int32> { return value + 100; }
}

let counter: int32 = 0;
function bump(tag: string): int32 {
	counter = counter + 1;
	console.log(`bump ${tag}`);
	return counter;
}

async function main(): Promise<void> {
	console.log(await later(await seven()));
	const deferred = await later(bump("deferred"));
	console.log(`| ${deferred}`);
	console.log(await shifted(await seven()));
	console.log(await shifted(bump("top")));
}
main();
