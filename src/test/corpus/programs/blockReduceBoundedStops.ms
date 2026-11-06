// @exit: 1
// @stdout: sum 2045901696
// @stdout: nested 2045901696
// @stdout: drain -2045901696
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the int32 sum wraps instead of stopping
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms and src/codegen/raiser/eval.ms pin the raiser check
// note: a generator's masked int32 reduction sums through range-guarded blocks of 1024, then stops where the sum passes MAX.

function* upTo(limit: int32): Iterator<int32> {
	for (let i: int32 = 0; i < limit; i++) yield i;
}

function* relay(limit: int32): Iterator<int32> {
	for (const x of upTo(limit)) yield x;
}

function sum(n: int32, salt: int32): int32 {
	let total: int32 = 0;
	for (const x of upTo(n)) total += (x ^ salt) & 1023;
	return total;
}

function nested(n: int32, salt: int32): int32 {
	let total: int32 = 0;
	for (const x of relay(n)) total += (x ^ salt) & 1023;
	return total;
}

function drain(n: int32, salt: int32): int32 {
	let total: int32 = 0;
	for (const x of upTo(n)) total -= (x | salt) & 1023;
	return total;
}

function main(): void {
	console.log(`sum ${sum(4000000, 5)}`);
	console.log(`nested ${nested(4000000, 5)}`);
	console.log(`drain ${drain(4000000, 0)}`);
	console.log(sum(5000000, 5));
	console.log("unreachable");
}

main();
