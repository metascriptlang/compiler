// @exit: 1
// @stdout: 4993
// @stdout: division by zero
// @xfail(danger): --danger keeps no zero-divisor check, so the division is undefined behaviour there instead of a stop
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms and src/codegen/raiser/eval.ms pin the raiser check
// note: a generator's masked reduction whose body declares a cast of a division keeps that division in every block, so a
// range-guarded block cannot skip the division by zero it raises.

function* upTo(limit: int32): Iterator<int32> {
	for (let i: int32 = 0; i < limit; i++) yield i;
}

function masked(n: int32, z: int32): int32 {
	let total: int32 = 0;
	for (const x of upTo(n)) {
		const q = (100 / z) as number;
		total += x & 3;
	}
	return total;
}

console.log(masked(3330, 7));
console.log(masked(3330, 0));
