// @stdout: bigint ops done

// bigint is arbitrary-precision on both backends: C routes every operator to a
// runtime call over an mbedTLS mpi, js uses the native BigInt. The two must agree
// bit for bit — including the signs C inherits from truncated division and the
// two's-complement view of a negative operand under & | ^ ~ >>.

interface Box { v: bigint; }
struct SBox { v: bigint; }

function check(name: string, ok: boolean): boolean {
	if (!ok) { console.log("FAIL " + name); }
	return ok;
}

function literals(): boolean {
	let ok = check("dec", (255n).toString() == "255");
	ok = check("hex", (0xffn).toString() == "255") && ok;
	ok = check("bin", (0b1111n).toString() == "15") && ok;
	ok = check("oct", (0o17n).toString() == "15") && ok;
	ok = check("underscore", (1_000_000n).toString() == "1000000") && ok;
	ok = check("neg", (-42n).toString() == "-42") && ok;
	return ok;
}

function arithmetic(): boolean {
	let ok = check("add", (2n + 3n).toString() == "5");
	ok = check("sub", (2n - 5n).toString() == "-3") && ok;
	ok = check("mul", (7n * 6n).toString() == "42") && ok;
	ok = check("divTrunc", (7n / 2n).toString() == "3") && ok;
	ok = check("divNegNum", (-7n / 2n).toString() == "-3") && ok;
	ok = check("divNegDen", (7n / -2n).toString() == "-3") && ok;
	ok = check("divNegBoth", (-7n / -2n).toString() == "3") && ok;
	ok = check("remSign", (-7n % 2n).toString() == "-1") && ok;
	ok = check("remSignDen", (7n % -2n).toString() == "1") && ok;
	ok = check("pow", (2n ** 64n).toString() == "18446744073709551616") && ok;
	ok = check("huge", (2n ** 100n + 1n).toString() == "1267650600228229401496703205377") && ok;
	return ok;
}

function bitwise(): boolean {
	let ok = check("and", (12n & 10n).toString() == "8");
	ok = check("or", (12n | 10n).toString() == "14") && ok;
	ok = check("xor", (12n ^ 10n).toString() == "6") && ok;
	ok = check("notPos", (~5n).toString() == "-6") && ok;
	ok = check("notNeg", (~-5n).toString() == "4") && ok;
	ok = check("andNeg", (-12n & 10n).toString() == "0") && ok;
	ok = check("orNeg", (-12n | 10n).toString() == "-2") && ok;
	ok = check("xorNeg", (-12n ^ 10n).toString() == "-2") && ok;
	ok = check("shl", (1n << 70n).toString() == "1180591620717411303424") && ok;
	ok = check("shr", (1024n >> 3n).toString() == "128") && ok;
	ok = check("shrNegFloor", (-5n >> 1n).toString() == "-3") && ok;
	return ok;
}

function comparisons(): boolean {
	let ok = check("lt", 2n < 3n);
	ok = check("gt", 5n > 3n) && ok;
	ok = check("le", 3n <= 3n) && ok;
	ok = check("ge", 3n >= 3n) && ok;
	ok = check("eq", 42n == 42n) && ok;
	ok = check("ne", 42n != 43n) && ok;
	ok = check("mixedLt", 1n < 2) && ok;
	ok = check("mixedGt", 2 > 1n) && ok;
	ok = check("hugeCmp", 2n ** 90n > 2n ** 89n) && ok;
	return ok;
}

function truthiness(): boolean {
	const z: bigint = 0n;
	const nz: bigint = 5n;
	let ok = check("zeroFalsy", !z);
	ok = check("nonZeroTruthy", !(!nz)) && ok;
	let hit = 0;
	if (z) { hit = 1; }
	if (nz) { hit = hit + 2; }
	ok = check("branch", hit == 2) && ok;
	return ok;
}

function conversions(): boolean {
	const n: int32 = 1234;
	const b: bigint = n as bigint;
	const back: float64 = b as float64;
	const narrowed: int32 = (255n) as int32;
	const parsed: bigint = "0xff" as bigint;
	let ok = check("intToBig", b.toString() == "1234");
	ok = check("bigToFloat", back == 1234.0) && ok;
	ok = check("bigToInt", narrowed == 255) && ok;
	ok = check("strToBig", parsed.toString() == "255") && ok;
	ok = check("typeofBig", typeof b == "bigint") && ok;
	return ok;
}

function radix(): boolean {
	let ok = check("radix2", (255n).toString(2) == "11111111");
	ok = check("radix16", (255n).toString(16) == "ff") && ok;
	ok = check("radix36", (1295n).toString(36) == "zz") && ok;
	ok = check("radixNeg", (-255n).toString(16) == "-ff") && ok;
	return ok;
}

function mutation(): boolean {
	let acc: bigint = 0n;
	for (let i = 0; i < 10; i += 1) { acc += 3n; }
	let cnt: bigint = 0n;
	cnt++;
	cnt++;
	let ok = check("compound", acc.toString() == "30");
	ok = check("increment", cnt.toString() == "2") && ok;
	return ok;
}

function containers(): boolean {
	const arr: bigint[] = new Array(8);
	for (let i = 0; i < 8; i += 1) { arr[i] = (i as bigint) * 11n; }
	let sum: bigint = 0n;
	for (const x of arr) { sum = sum + x; }
	const box: Box = { v: 0n };
	for (let i = 0; i < 20; i += 1) { box.v = i as bigint; }
	const sbox: SBox = { v: 99n };
	let ok = check("arraySum", sum.toString() == "308");
	ok = check("interfaceField", box.v.toString() == "19") && ok;
	ok = check("structField", sbox.v.toString() == "99") && ok;
	ok = check("interpolation", `v=${sbox.v}` == "v=99") && ok;
	ok = check("concat", "n=" + box.v.toString() == "n=19") && ok;
	return ok;
}

function main(): void {
	let ok = literals();
	ok = arithmetic() && ok;
	ok = bitwise() && ok;
	ok = comparisons() && ok;
	ok = truthiness() && ok;
	ok = conversions() && ok;
	ok = radix() && ok;
	ok = mutation() && ok;
	ok = containers() && ok;
	if (!ok) { console.log("bigint ops FAILED"); return; }
	console.log("bigint ops done");
}
main();
