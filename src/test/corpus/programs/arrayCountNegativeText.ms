// @exit: 1
// @stdout: value -5 not in range 0 .. 2147483647
function count(n: int32): int32 {
	return n;
}

console.log("before");
const bad = new Array<string>(count(-5));
console.log(`unreachable ${bad.length}`);
