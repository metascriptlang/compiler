// @exit: 1
// @stdout: value -1 not in range 0 .. 2147483647
function size(n: int32): number {
	return n;
}

console.log("before");
const bad = Buffer.alloc(size(-1));
console.log(`unreachable ${bad.length}`);
