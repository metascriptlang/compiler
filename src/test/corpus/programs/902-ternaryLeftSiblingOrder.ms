// @stdout: binary: atb x=3|args: atb y=3|index: atb z=1|arm: aatb
let log = "";
function a(): int32 { log = log + "a"; return 1; }
function b(): int32 { log = log + "b"; return 2; }
function t(): boolean { log = log + "t"; return true; }
function take(x: int32, y: int32): int32 { return x + y; }
function run(): void {
	const x = a() + (t() ? b() : 0);
	const l1 = log;
	log = "";
	const y = take(a(), t() ? b() : 0);
	const l2 = log;
	log = "";
	const xs: int32[] = [0, 1, 2, 3];
	const z = xs[a() + (t() ? b() : 0) - 2];
	const l3 = log;
	log = "";
	const flag = a() > 0 ? a() + (t() ? b() : 0) : 0;
	console.log("binary: " + l1 + " x=" + x.toString() + "|args: " + l2 + " y=" + y.toString()
		+ "|index: " + l3 + " z=" + z.toString() + "|arm: " + log);
	console.log(flag);
}
run();
