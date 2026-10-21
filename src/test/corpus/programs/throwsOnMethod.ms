// @stdout: free: 2
// @stdout: method: 4
// @stdout: static: 6
// @stdout: caught: too big 9
@throws
function freeStep(n: int32): int32 { return n + 1; }
class Stepper {
	limit: int32;
	constructor(limit: int32) { this.limit = limit; }
	@throws
	step(n: int32): int32 {
		if (n > this.limit) throw new Error(`too big ${n}`);
		return n + 2;
	}
	@throws
	static twice(n: int32): int32 { return n * 2; }
}
function run(): void {
	const s = new Stepper(5);
	console.log("free: " + freeStep(1).toString());
	console.log("method: " + s.step(2).toString());
	console.log("static: " + Stepper.twice(3).toString());
	try {
		s.step(9);
	} catch (e) {
		console.log("caught: " + (e as Error).message);
	}
}
run();
