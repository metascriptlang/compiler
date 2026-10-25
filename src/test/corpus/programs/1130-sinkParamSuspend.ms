// @maxrss: 30
// @stdout: sink-param-suspend 200000 200000
async function take(sink v: string): Promise<number> {
	await Promise.resolve(1);
	return v.length > 0 ? 1 : 0;
}
function* walk(sink v: string): Iterator<int32> {
	yield v.length > 0 ? 1 : 0;
}
async function main(): Promise<void> {
	const pad = "x".repeat(160);
	let awaited: number = 0;
	let yielded: number = 0;
	for (let k = 0; k < 200000; k++) {
		const a = `${k} ${pad}`;
		awaited += await take(move a);
		for (const n of walk(`${k} ${pad}`)) yielded += n;
	}
	console.log("sink-param-suspend", awaited, yielded);
}
main();
