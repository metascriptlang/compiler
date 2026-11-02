// @stdout: s:seven!!
// @stdout: b:3
// @stdout: s:again
function describe(held: Buffer | string): string {
	return typeof held == "string" ? `s:${held}` : `b:${held.length}`;
}

function run(): void {
	let held: Buffer | string = "seven!!";
	console.log(describe(held));
	const raw: uint8[] = [1, 2, 3];
	held = raw as Buffer;
	console.log(describe(held));
	held = "again";
	console.log(describe(held));
}
run();
