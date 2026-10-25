// @exit: 1
// @stdout: value 4611686018427387905 not in range 0 .. 2147483647
// @xfail(raiser): the Raiser VM reports the defect as its own 'raiser runtime error' on stderr, not the shared 'Error: ' line; the opcode is pinned by the NewArray count tests in src/raiser/vm.ms
function count(n: int64): int64 {
	return n;
}

console.log("before");
const bad = new Array<uint64>(count(4611686018427387905));
console.log(`unreachable ${bad.length}`);
