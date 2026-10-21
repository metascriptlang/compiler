// @exit: 1
// @stdout: length 3
// @stdout: value 2147483648 not in range 0 .. 2147483647
// @xfail(raiser): the Raiser VM reports the defect as its own 'raiser runtime error' on stderr, not the shared 'Error: ' line; the opcode is pinned by the NewArray count tests in src/raiser/vm.ms
function count(n: int64): int64 {
	return n;
}

const small = new Array<uint8>(count(3));
console.log(`length ${small.length}`);
const bad = new Array<uint8>(count(2147483648));
console.log(`unreachable ${bad.length}`);
