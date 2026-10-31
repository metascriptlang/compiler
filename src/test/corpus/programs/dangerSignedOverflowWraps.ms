// @stdout: wrapped 8
// @xfail(c): the default build stops on a signed overflow instead of wrapping
// @xfail(js): the default JS build stops on a signed overflow instead of wrapping
// @xfail(esm): the default JS build stops on a signed overflow instead of wrapping
// @skip-raiser: the raiser stops on a signed overflow and writes it to stderr
// note: --danger drops the overflow check, and int32 wraps as the JS --danger build wraps it, so the loop ends instead of being undefined behaviour the optimiser may turn into a loop that never ends.

function countToWrap(): int32 {
	let n: int32 = 0;
	for (let i: int32 = 2147483640; i > 0; i += 1) n += 1;
	return n;
}

console.log(`wrapped ${countToWrap()}`);
