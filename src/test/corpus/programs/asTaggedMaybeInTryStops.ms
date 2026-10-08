// @exit: 1
// @stdout: before 7
// @xfail(danger): --danger drops the union member check
// @xfail(raiser): fatal VM errors use a different stderr report from C and JS

function pick(k: int32): int32 | float64 | null {
	if (k == 0) return 7;
	if (k == 1) return null;
	return 1.5;
}

const nil = pick(1) as int32 | null;
if (nil != null) process.exit(2);
const held = pick(0) as int32 | null;
if (held == null) process.exit(2);
console.log("before " + held!.toString());
try {
	const wrong = pick(2) as int32 | null;
	console.log("wrong " + String(wrong));
} catch (e) {
	console.log("caught");
}
console.log("after");
