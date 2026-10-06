// @exit: 1
// @stdout: before 42
// @xfail(danger): --danger drops the tag test, so the read of the other member is undefined behaviour
// @xfail(raiser): the Raiser VM does not test union conversions

function numOrText(k: int32): int32 | string {
	if (k == 0) return 41;
	return "s";
}

function asInt(k: int32): int32 { return numOrText(k) as int32; }

console.log(`before ${asInt(0) + 1}`);
console.log(`after ${asInt(1) + 1}`);
