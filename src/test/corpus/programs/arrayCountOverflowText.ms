// @exit: 1
// @stdout: value 576460752303423488 not in range 0 .. 2147483647
function count(n: int64): int64 {
	return n;
}

console.log("before");
const bad = new Array<string>(count(576460752303423488));
console.log(`unreachable ${bad.length}`);
