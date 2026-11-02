// @stdout: text=hi
// @stdout: text=null
// @stdout: box=7
class Box {
	value: int32;
	constructor(value: int32) { this.value = value; }
}

function text(ok: boolean): Result<string, string> { return ok ? Result.ok("hi") : Result.err("no"); }
function box(): Result<Box, string> { return Result.ok(new Box(7)); }

function run(): void {
	const a = try text(true) catch null;
	console.log(`text=${a == null ? "null" : a}`);
	const b = try text(false) catch null;
	console.log(`text=${b == null ? "null" : b}`);
	const c = try box() catch null;
	console.log(`box=${c == null ? "null" : c.value}`);
}
run();
