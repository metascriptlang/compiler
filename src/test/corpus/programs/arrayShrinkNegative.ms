// @exit: 1
// @stdout: value -3 not in range 0 .. 2
// @xfail(raiser): the Raiser VM reports the defect as its own 'raiser runtime error' on stderr, not the shared 'Error: ' line
function count(n: int32): int32 {
	return n;
}

console.log("before");
const nums: int32[] = [1, 2];
nums.shrink(count(-3));
console.log(`unreachable ${nums.length}`);
