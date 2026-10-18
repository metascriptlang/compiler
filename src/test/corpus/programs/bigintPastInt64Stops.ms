// @exit: 1
// @stdout: value 9223372036854775808 not in range -9223372036854775808 .. 9223372036854775807
// @xfail(raiser): bigint is not supported on the Raiser VM

function main(): void {
	const b: bigint[] = [9223372036854775808n];
	console.log("before");
	console.log(`${b[0] as int64}`);
	console.log("unreachable");
}

main();
