// @xfail(raiser): error: Undefined variable 'BigInt'

function main(): void {
	const bad: string[] = ["-0x10", "+0x10", "-0b1", "1_000", "12n", "-", "0x", "0x1g", " 1x ", "1.5"];
	for (const s of bad) {
		try {
			console.log(`accepted ${BigInt(s)}`);
		} catch (e) {
			console.log(`caught ${e.message}`);
		}
	}
	const good: string[] = [" -12 ", "0x10", "0b11", "0o7", "", "+5"];
	for (const s of good) {
		try {
			console.log(`parsed ${BigInt(s)}`);
		} catch (e) {
			console.log(`caught ${e.message}`);
		}
	}
	console.log(`sum ${BigInt("0x10") + 1n}`);
}

main();
