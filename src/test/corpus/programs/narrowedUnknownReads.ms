// @stdout: unknown 7 7 7 0 true false

class Box { n: number; }
function isBox(value: unknown): value is Box { return value !== null; }
function read(value: unknown): number {
	if (isBox(value)) return value.n;
	return 0;
}
function run(): void {
	const box = new Box();
	box.n = 7.0;
	const value = box as unknown;
	let local: number = -1;
	let cast: number = -1;
	if (isBox(value)) {
		local = value.n;
		cast = (value as Box).n;
	}
	console.log(`unknown ${local} ${cast} ${read(value)} ${read(null)} ${isBox(value)} ${isBox(null)}`);
}
run();
