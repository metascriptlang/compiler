// @exit: 1
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the sum is undefined in C instead of stopping
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms and src/codegen/raiser/eval.ms pin the raiser check
// note: `+=` on an int64 field stops when the stored sum leaves int64; the field is evaluated once.

class Account { balance: int64 = 0; }

let reads = 0;
function account(a: Account): Account {
	reads += 1;
	return a;
}

function main(): void {
	const a = new Account();
	a.balance = 9223372036854775806;
	account(a).balance += 1;
	console.log(`kept ${a.balance} reads=${reads}`);
	account(a).balance += 1;
	console.log("unreachable");
}

main();
