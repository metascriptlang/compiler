// Parity program — the comptime engine tells a bigint from a string in a `string | bigint`
// union, and a bigint a comptime block computes reaches the program as that bigint.
//
// @stdout: B4,Sx,B36893488147419103233
// @stdout: -1180591620717411303424 -1180591620717411303423
// @exit: 0

const tagged: string = @comptime {
	const xs: (string | bigint)[] = [3n, "x", 2n ** 65n];
	let s = "";
	for (const x of xs) {
		if (s != "") s += ",";
		s += typeof x === "bigint" ? "B" + (x + 1n).toString() : "S" + x;
	}
	return s;
};

const folded: bigint = @comptime {
	return -(2n ** 70n);
};

console.log(tagged);
console.log(folded.toString(), (folded + 1n).toString());
