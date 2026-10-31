// @exit: 1
// @stdout: value -1 not in range 0 .. 2147483647
// @xfail(raiser): the Raiser VM reports the defect as its own 'raiser runtime error' on stderr, not the shared 'Error: ' line; the opcode is pinned by the NewArray count tests in src/raiser/vm.ms
function size(n: int32): number {
	return n;
}

console.log("before");
const bad = Buffer.alloc(size(-1));
console.log(`unreachable ${bad.length}`);
