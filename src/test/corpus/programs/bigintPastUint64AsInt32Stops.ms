// @exit: 1
// @stdout: value 18446744073709551617 not in range -2147483648 .. 2147483647
// @xfail(raiser): bigint is not supported on the Raiser VM

function main(): void {
	const b: bigint[] = [18446744073709551617n];
	console.log("before");
	console.log(`${b[0] as int32}`);
	console.log("unreachable");
}

main();
