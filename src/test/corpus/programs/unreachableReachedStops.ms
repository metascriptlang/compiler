// @exit: 1
// @stdout: before 1
// @xfail(raiser): fatal VM errors use a different stderr report from C and JS
// note: reaching `unreachable` stops the program, inside a `try` too; JS used to throw a catchable error and the Raiser returned nil.

function sign(x: int32): int32 {
	if (x > 0) return 1;
	if (x < 0) return -1;
	unreachable;
}

console.log(`before ${sign(4)}`);
try {
	console.log(`zero ${sign(0)}`);
} catch (e) {
	console.log("caught");
}
console.log("after");
