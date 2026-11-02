// @exit: 1
// @stdout: index -1 out of bounds (length 0)
function run(): void {
	const a: string[] = [];
	console.log(`len=${a.length}`);
	const s = a.pop();
	console.log(`unreachable '${s}'`);
}

run();
