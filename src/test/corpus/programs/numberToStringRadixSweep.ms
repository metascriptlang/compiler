// @stdout: radix 2 float 215693347 int 922643896 uint 9893958
// @stdout: radix 3 float 794414426 int 252919714 uint 30454677
// @stdout: radix 4 float 436648189 int 309253628 uint 997709816
// @stdout: radix 5 float 815337108 int 17959243 uint 390128544
// @stdout: radix 6 float 843965130 int 481294424 uint 709964238
// @stdout: radix 7 float 289671676 int 273385405 uint 11192603
// @stdout: radix 8 float 372732729 int 622626496 uint 515778446
// @stdout: radix 9 float 412271582 int 320507832 uint 567977499
// @stdout: radix 10 float 254889122 int 663927424 uint 212063849
// @stdout: radix 11 float 847004999 int 284460540 uint 648608262
// @stdout: radix 12 float 284145330 int 750396500 uint 394058938
// @stdout: radix 13 float 258607102 int 966302151 uint 738377896
// @stdout: radix 14 float 260542548 int 395866538 uint 688652876
// @stdout: radix 15 float 947666587 int 631347779 uint 213615801
// @stdout: radix 16 float 94870020 int 458765387 uint 744663472
// @stdout: radix 17 float 9138563 int 482465801 uint 355130036
// @stdout: radix 18 float 184654590 int 488306595 uint 563506382
// @stdout: radix 19 float 204342457 int 705638418 uint 425054324
// @stdout: radix 20 float 479844012 int 777194469 uint 389862766
// @stdout: radix 21 float 955683740 int 810940068 uint 669169759
// @stdout: radix 22 float 317850455 int 618393184 uint 311441733
// @stdout: radix 23 float 871688437 int 9671940 uint 945362553
// @stdout: radix 24 float 659053041 int 298003550 uint 420746652
// @stdout: radix 25 float 118870127 int 194474457 uint 821615362
// @stdout: radix 26 float 579811790 int 185254080 uint 720159258
// @stdout: radix 27 float 749578031 int 838948712 uint 385931330
// @stdout: radix 28 float 480425085 int 356047104 uint 463501787
// @stdout: radix 29 float 663506251 int 148406182 uint 232157138
// @stdout: radix 30 float 397904011 int 996139358 uint 536616267
// @stdout: radix 31 float 373489335 int 989643656 uint 925560008
// @stdout: radix 32 float 16126497 int 69974775 uint 333160327
// @stdout: radix 33 float 284375256 int 575131466 uint 773531376
// @stdout: radix 34 float 728810409 int 746028144 uint 948641667
// @stdout: radix 35 float 689146382 int 299909348 uint 369405725
// @stdout: radix 36 float 143299490 int 324021412 uint 585885668
// @stdout: r2 min -1000000000000000000000000000000000000000000000000000000000000000 max 111111111111111111111111111111111111111111111111111111111111111 umax 1111111111111111111111111111111111111111111111111111111111111111 neg -11111111
// @stdout: r2 frac 1.1 0.0001100110011001100110011001100110011001100110011001101 -11111111.1 -0 NaN -Infinity
// @stdout: r2 big 1101100011010111001001101011011100010111011110101000000000000000000000 11.00100100001111110011111000000011011100001100110111
// @stdout: r7 min -22341010611245052052301 max 22341010611245052052300 umax 45012021522523134134601 neg -513
// @stdout: r7 frac 1.3333333333333333334 0.04620462046204620463 -513.33333333333333334 -0 NaN -Infinity
// @stdout: r7 big 5135235413265003022600000 3.066364631133534554
// @stdout: r16 min -8000000000000000 max 7fffffffffffffff umax ffffffffffffffff neg -ff
// @stdout: r16 frac 1.8 0.1999999999999a -ff.8 -0 NaN -Infinity
// @stdout: r16 big 3635c9adc5dea00000 3.243f3e0370cdc
// @stdout: r36 min -1y2p0ij32e8e8 max 1y2p0ij32e8e7 umax 3w5e11264sgsf neg -73
// @stdout: r36 frac 1.i 0.3lllllllllm -73.i -0 NaN -Infinity
// @stdout: r36 big 5v1j4f4ds7c000 3.53i0tuycp
// note: toString(radix) over every radix 2..36 for float64, int64 and uint64 prints one digest per radix and a few full samples.

const floats: float64[] = [
	1.5, 0.1, 255.5, -255.5, 1e21, 9007199254740992.0, 9223372036854775808.0, 18446744073709551616.0,
	1.7976931348623157e308, 5e-324, 2.2250738585072014e-308, 0.000001, -0.0, 0.0, Number.NaN,
	Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY, 123.456, 3.14159, 0.5, 0.3333333333333333,
	100.0, 37.0, 35.0, -1e-300, 4503599627370496.0, 0.999999999999999, 0.6666666666666666,
	6.02214076e23, -9007199254740992.0, 1e-7, 12345.6789, 0.9999999999999999, 1e15, -1e15 - 0.5,
];
const ints: int64[] = [
	-9223372036854775807 - 1, 9223372036854775807, -1, 0, 1, 255, -255, 36, -36, 9007199254740993,
	-9007199254740993, 4294967296, -4294967296,
];
const uints: uint64[] = [18446744073709551615, 9223372036854775808, 9223372036854775807, 0, 1, 35, 36, 4294967296];

function negativeZero(v: float64): boolean {
	return v == 0.0 && Math.atan2(v, -1.0) < 0.0;
}

function floatText(v: float64, radix: int32): string {
	return negativeZero(v) ? "-0" : v.toString(radix);
}

function fold(h: float64, s: string): float64 {
	let x = h;
	for (let i = 0; i < s.length; i++) x = (x * 131.0 + s.charCodeAt(i) as float64) % 1000000007.0;
	return (x * 131.0 + 124.0) % 1000000007.0;
}

for (let r: int32 = 2; r <= 36; r++) {
	let hf = 7.0;
	for (let i = 0; i < floats.length; i++) hf = fold(hf, floatText(floats[i], r));
	let hi = 7.0;
	for (let i = 0; i < ints.length; i++) hi = fold(hi, ints[i].toString(r));
	let hu = 7.0;
	for (let i = 0; i < uints.length; i++) hu = fold(hu, uints[i].toString(r));
	console.log(`radix ${r} float ${hf} int ${hi} uint ${hu}`);
}

const sampleRadixes: int32[] = [2, 7, 16, 36];
for (let k = 0; k < sampleRadixes.length; k++) {
	const r = sampleRadixes[k];
	console.log(`r${r} min ${ints[0].toString(r)} max ${ints[1].toString(r)} umax ${uints[0].toString(r)} neg ${ints[6].toString(r)}`);
	console.log(`r${r} frac ${floatText(floats[0], r)} ${floatText(floats[1], r)} ${floatText(floats[3], r)} ${floatText(floats[12], r)} ${floatText(floats[14], r)} ${floatText(floats[16], r)}`);
	console.log(`r${r} big ${floatText(floats[4], r)} ${floatText(floats[18], r)}`);
}
