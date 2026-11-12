// @exit: 1
// @stdout: inside 7
// @xfail(danger): --danger drops bound checks, so the out-of-range index is undefined behaviour there, not an index error
// note: a uint8 index into a fixed array shorter than 256 elements keeps its check: 200 into 100 elements stops.

let short: uint32[100] = [];

function byByte(b: uint8): uint32 {
	return short[b];
}

short[99] = 7;
console.log(`inside ${byByte(99)}`);
console.log(`unreachable ${byByte(200)}`);
