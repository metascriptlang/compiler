// @stdout: 16777215,16777216,16777216,16777218,16777220
// note: a masked integer held in a float32 const and cast back reads the float32 value, rounded above 2^24, not the
// integer behind it (only a float64 const holds every masked integer up to 2^53 exactly).

function roundTrip(i: int64): int64 {
	const k: float32 = (i & 67108863) as float32;
	return k as int64;
}

const out: string[] = [];
for (let j: int64 = 16777215; j < 16777220; j++) out.push(roundTrip(j).toString());
console.log(out.join(","));
