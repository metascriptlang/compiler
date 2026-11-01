// @stdout: 80 -3041 27 79 -3240
// note: an 80-entry table of tuple literals, and 80-entry boolean, enum and negative int32 literals, are initialised from one static data blob; tuples hold numbers, a boolean and an enum member.
enum Color { Red, Green, Blue }

function tupleSum(): number {
	const T: [int32, boolean, int32, Color][] = [
		[0, true, 0, Color.Red],
		[1, false, -2, Color.Green],
		[2, true, -4, Color.Blue],
		[3, false, -6, Color.Red],
		[4, true, -8, Color.Green],
		[5, false, -10, Color.Blue],
		[6, true, -12, Color.Red],
		[7, false, -14, Color.Green],
		[8, true, -16, Color.Blue],
		[9, false, -18, Color.Red],
		[10, true, -20, Color.Green],
		[11, false, -22, Color.Blue],
		[12, true, -24, Color.Red],
		[13, false, -26, Color.Green],
		[14, true, -28, Color.Blue],
		[15, false, -30, Color.Red],
		[16, true, -32, Color.Green],
		[17, false, -34, Color.Blue],
		[18, true, -36, Color.Red],
		[19, false, -38, Color.Green],
		[20, true, -40, Color.Blue],
		[21, false, -42, Color.Red],
		[22, true, -44, Color.Green],
		[23, false, -46, Color.Blue],
		[24, true, -48, Color.Red],
		[25, false, -50, Color.Green],
		[26, true, -52, Color.Blue],
		[27, false, -54, Color.Red],
		[28, true, -56, Color.Green],
		[29, false, -58, Color.Blue],
		[30, true, -60, Color.Red],
		[31, false, -62, Color.Green],
		[32, true, -64, Color.Blue],
		[33, false, -66, Color.Red],
		[34, true, -68, Color.Green],
		[35, false, -70, Color.Blue],
		[36, true, -72, Color.Red],
		[37, false, -74, Color.Green],
		[38, true, -76, Color.Blue],
		[39, false, -78, Color.Red],
		[40, true, -80, Color.Green],
		[41, false, -82, Color.Blue],
		[42, true, -84, Color.Red],
		[43, false, -86, Color.Green],
		[44, true, -88, Color.Blue],
		[45, false, -90, Color.Red],
		[46, true, -92, Color.Green],
		[47, false, -94, Color.Blue],
		[48, true, -96, Color.Red],
		[49, false, -98, Color.Green],
		[50, true, -100, Color.Blue],
		[51, false, -102, Color.Red],
		[52, true, -104, Color.Green],
		[53, false, -106, Color.Blue],
		[54, true, -108, Color.Red],
		[55, false, -110, Color.Green],
		[56, true, -112, Color.Blue],
		[57, false, -114, Color.Red],
		[58, true, -116, Color.Green],
		[59, false, -118, Color.Blue],
		[60, true, -120, Color.Red],
		[61, false, -122, Color.Green],
		[62, true, -124, Color.Blue],
		[63, false, -126, Color.Red],
		[64, true, -128, Color.Green],
		[65, false, -130, Color.Blue],
		[66, true, -132, Color.Red],
		[67, false, -134, Color.Green],
		[68, true, -136, Color.Blue],
		[69, false, -138, Color.Red],
		[70, true, -140, Color.Green],
		[71, false, -142, Color.Blue],
		[72, true, -144, Color.Red],
		[73, false, -146, Color.Green],
		[74, true, -148, Color.Blue],
		[75, false, -150, Color.Red],
		[76, true, -152, Color.Green],
		[77, false, -154, Color.Blue],
		[78, true, -156, Color.Red],
		[79, false, -158, Color.Green],
	];
	let s: number = 0;
	for (const t of T) s += (t[0] as number) + (t[1] ? 1 : 0) + (t[2] as number) + (t[3] as number);
	return s + T.length * 0;
}

const B: boolean[] = [true, false, false, true, false, false, true, false, false, true, false, false, true, false, false, true, false, false, true, false, false, true, false, false, true, false, false, true, false, false, true, false, false, true, false, false, true, false, false, true, false, false, true, false, false, true, false, false, true, false, false, true, false, false, true, false, false, true, false, false, true, false, false, true, false, false, true, false, false, true, false, false, true, false, false, true, false, false, true, false];
const C: Color[] = [Color.Red, Color.Green, Color.Blue, Color.Red, Color.Green, Color.Blue, Color.Red, Color.Green, Color.Blue, Color.Red, Color.Green, Color.Blue, Color.Red, Color.Green, Color.Blue, Color.Red, Color.Green, Color.Blue, Color.Red, Color.Green, Color.Blue, Color.Red, Color.Green, Color.Blue, Color.Red, Color.Green, Color.Blue, Color.Red, Color.Green, Color.Blue, Color.Red, Color.Green, Color.Blue, Color.Red, Color.Green, Color.Blue, Color.Red, Color.Green, Color.Blue, Color.Red, Color.Green, Color.Blue, Color.Red, Color.Green, Color.Blue, Color.Red, Color.Green, Color.Blue, Color.Red, Color.Green, Color.Blue, Color.Red, Color.Green, Color.Blue, Color.Red, Color.Green, Color.Blue, Color.Red, Color.Green, Color.Blue, Color.Red, Color.Green, Color.Blue, Color.Red, Color.Green, Color.Blue, Color.Red, Color.Green, Color.Blue, Color.Red, Color.Green, Color.Blue, Color.Red, Color.Green, Color.Blue, Color.Red, Color.Green, Color.Blue, Color.Red, Color.Green];
const N: int32[] = [-1, -2, -3, -4, -5, -6, -7, -8, -9, -10, -11, -12, -13, -14, -15, -16, -17, -18, -19, -20, -21, -22, -23, -24, -25, -26, -27, -28, -29, -30, -31, -32, -33, -34, -35, -36, -37, -38, -39, -40, -41, -42, -43, -44, -45, -46, -47, -48, -49, -50, -51, -52, -53, -54, -55, -56, -57, -58, -59, -60, -61, -62, -63, -64, -65, -66, -67, -68, -69, -70, -71, -72, -73, -74, -75, -76, -77, -78, -79, -80];

let bc = 0;
for (const b of B) if (b) bc += 1;
let cc: number = 0;
for (const c of C) cc += c as number;
let ns: number = 0;
for (const n of N) ns += n as number;
console.log(B.length, tupleSum(), bc, cc, ns);
