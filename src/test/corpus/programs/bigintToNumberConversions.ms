// @xfail(raiser): error: cannot compile node kind BigIntLiteral

function main(): void {
	const s: bigint[] = [9223372036854775807n, -9223372036854775808n, 127n, -128n, 2147483647n, -2147483648n];
	console.log(`signed ${s[0] as int64} ${s[1] as int64} ${s[2] as int8} ${s[3] as int8} ${s[4] as int32} ${s[5] as int32}`);
	const u: bigint[] = [18446744073709551916n, -1n, -9223372036854775808n];
	console.log(`unsigned ${u[0] as uint64} ${u[0] as uint8} ${u[1] as uint32} ${u[2] as uint64} ${u[1] as uint16}`);
	const f: bigint[] = [16777217n, 1152921573326323713n, -16777219n, 340282356779733661637539395458142568447n, 340282356779733661637539395458142568448n];
	const stored: float32 = f[1] as float32;
	console.log(`float32 ${f[0] as float32} ${stored} ${f[2] as float32} ${f[3] as float32} ${f[4] as float32}`);
	const d: bigint[] = [9007199254740995n];
	console.log(`float64 ${d[0] as float64} ${d[0] as number}`);
	const text: string[] = [" -12 ", "0x10", "0X1f", "0b11", "0o7", "", "+5", "00012", "-0"];
	console.log(`parse ${BigInt(text[0])} ${BigInt(text[1])} ${BigInt(text[2])} ${BigInt(text[3])} ${BigInt(text[4])} ${BigInt(text[5])} ${BigInt(text[6])} ${BigInt(text[7])} ${BigInt(text[8])}`);
}

main();
