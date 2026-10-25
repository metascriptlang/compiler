// @exit: 1
// @stdout: value -1 not in range 0 .. 2147483647
// @xfail(raiser): the Raiser VM reports the defect as its own 'raiser runtime error' on stderr, not the shared 'Error: ' line; the opcode is pinned by the NewArray count tests in src/raiser/vm.ms
function count(n: int32): int32 {
	return n;
}

console.log("before");
const bad = new Array<uint64>(count(-1));
console.log(`unreachable ${bad.length}`);
