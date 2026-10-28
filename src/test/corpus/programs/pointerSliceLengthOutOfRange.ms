// @exit: 1
// @stdout: Error: slice 0..-1 out of bounds (length -1)
// @skip-js: a pointer has no memory to slice on JS; the checker refuses it there
// @xfail(raiser): the Raiser VM refuses slicing a pointer: it has no address arithmetic
// @xfail(danger): --danger drops bound checks, so the out-of-range length is undefined behaviour there, not a slice error
@include("stdlib.h")
extern function malloc(size: uint64): Ptr<void>;

function viewLength(bytes: Ptr<uint8>, n: uint64): int64 {
	return bytes[0..n].length;
}

const bytes = malloc(4) as Ptr<uint8>;
console.log(`${viewLength(bytes, 3)}`);
console.log(`unreachable ${viewLength(bytes, 18446744073709551615)}`);
