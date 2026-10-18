// @exit: 1
// @stdout: value -9007199254740993 not in range -32768 .. 32767
// @xfail(raiser): bigint is not supported on the Raiser VM

function main(): void {
	const b: bigint[] = [-9007199254740993n];
	console.log("before");
	console.log(`${b[0] as int16}`);
	console.log("unreachable");
}

main();
