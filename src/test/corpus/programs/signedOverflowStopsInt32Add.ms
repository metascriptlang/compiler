// @exit: 1
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the sum is undefined in C instead of stopping
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms and src/codegen/raiser/eval.ms pin the raiser check
// note: a signed sum, difference, product or negation that leaves its type stops on every backend; one that lands on a bound is kept.

function add(a: int32, b: int32): int32 { return a + b; }
function sub(a: int32, b: int32): int32 { return a - b; }
function mul(a: int32, b: int32): int32 { return a * b; }
function neg(a: int32): int32 { return -a; }

function main(): void {
	console.log(`bounds ${add(2147483646, 1)} ${sub(-2147483647, 1)} ${mul(-65536, 32768)} ${neg(-2147483647)}`);
	console.log(add(2147483647, 1));
	console.log("unreachable");
}

main();
