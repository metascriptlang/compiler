// @exit: 1
// @stdout: before 42 7
// @xfail(danger): --danger drops the tag test, so the read of the other member is undefined behaviour
// @xfail(raiser): the Raiser VM does not test union conversions

function wideOrText(k: int32): int64 | string {
	if (k == 0) return 41 as int64;
	return "s";
}

function countOrText(k: int32): uint64 | string {
	if (k == 0) return 7 as uint64;
	return "s";
}

function asWide(k: int32): int64 { return wideOrText(k) as int64; }

function asCount(k: int32): uint64 { return countOrText(k) as uint64; }

console.log(`before ${asWide(0) + 1} ${asCount(0)}`);
console.log(`after ${asCount(1)}`);
console.log(`after ${asWide(1) + 1}`);
