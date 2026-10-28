// @stdout: work 0
// @stdout: work 1
// @stdout: work 2
// @stdout: all 3
// @stdout: work 3
// @stdout: work 4
// @stdout: work 5
// @stdout: result 3
// @stdout: work 6
// @stdout: work 7
// @stdout: work 8
// @stdout: work 9
// @stdout: loop 4
// @exit: 0
// note: a Promise<void>[] awaited through Promise.all keeps one result slot per promise and the call emits (old C: the result array had an element of type void and the compile failed); the array is filled by push in a loop and the result is read

let order = 0;
async function work(): Promise<void> {
	console.log("work", order);
	order += 1;
}

async function main(): Promise<void> {
	const runs: Promise<void>[] = [];
	runs.push(work());
	runs.push(work());
	runs.push(work());
	await Promise.all(runs);
	console.log("all", order);
	const results = await Promise.all([work(), work(), work()]);
	console.log("result", results.length);
	const more: Promise<void>[] = [];
	for (let i = 0; i < 4; i++) more.push(work());
	const done = await Promise.all(more);
	console.log("loop", done.length);
}
await main();
