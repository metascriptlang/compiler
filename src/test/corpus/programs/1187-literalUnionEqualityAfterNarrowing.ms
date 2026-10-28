// @stdout: eq=seven,other,a,b
// @stdout: !eq=other,seven
// @stdout: order=seven,other
// @stdout: float=seven,other
// @stdout: flip=seven,other
// @stdout: pair=seven,other
// @stdout: both=seven,other
// @stdout: sw=seven,other,a
function eq(u: "a" | "b" | int32): string {
	if (u === "a") return "a";
	if (u === 7) return "seven";
	if (u === "b") return "b";
	return "other";
}

function notEq(u: "a" | "b" | int32): string {
	if (u === "a") return "a";
	if (u !== 7) return "other";
	return "seven";
}

function order(u: int32 | "a" | "b"): string {
	if (u === "a") return "a";
	if (u === 7) return "seven";
	return "other";
}

function float(u: "a" | "b" | float64): string {
	if (u === "a") return "a";
	if (u === 7) return "seven";
	return "other";
}

function flip(u: "a" | "b" | int32): string {
	if (u === "a") return "a";
	if (7 === u) return "seven";
	return "other";
}

function pair(u: "a" | int32): string {
	if (u === "a") return "a";
	if (u === 7) return "seven";
	return "other";
}

function both(u: "a" | "b" | int32): string {
	if (u === "a") return "a";
	if (u === "b") return "b";
	if (u === 7) return "seven";
	return "other";
}

function sw(u: "a" | "b" | int32): string {
	if (u === "a") return "a";
	switch (u) {
		case 7:
			return "seven";
		default:
			return "other";
	}
}

console.log(`eq=${eq(7)},${eq(8)},${eq("a")},${eq("b")}`);
console.log(`!eq=${notEq(8)},${notEq(7)}`);
console.log(`order=${order(7)},${order(8)}`);
console.log(`float=${float(7)},${float(8)}`);
console.log(`flip=${flip(7)},${flip(8)}`);
console.log(`pair=${pair(7)},${pair(8)}`);
console.log(`both=${both(7)},${both(8)}`);
console.log(`sw=${sw(7)},${sw(8)},${sw("a")}`);
