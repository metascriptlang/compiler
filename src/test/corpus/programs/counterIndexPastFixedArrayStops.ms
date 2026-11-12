// @exit: 1
// @stdout: inside 64
// @xfail(danger): --danger drops bound checks, so the out-of-range index is undefined behaviour there, not an index error
// note: a counter whose literal bound lets it pass the end of a fixed array keeps the check: index 64 into 64 elements stops.

let w: int32[64] = [];

function count(limit: int32): int32 {
	let n: int32 = 0;
	for (let i = 0; i < 65; i++) {
		if (i >= limit) break;
		w[i] = 1;
		n += w[i];
	}
	return n;
}

console.log(`inside ${count(64)}`);
console.log(`unreachable ${count(65)}`);
