// @stdout: num=other three other
// @stdout: numNe=other three other
// @stdout: pair=same diff same diff
// @stdout: plain=two other three
// @stdout: plainPair=same diff same
// @stdout: mixed=num-two str-b other
// @stdout: mixedPair=same diff diff same
function num(own: 1 | 2 | 3 | null): string {
	if (own === 3) return "three";
	return "other";
}

function numNe(own: 1 | 2 | 3 | null): string {
	if (own !== 3) return "other";
	return "three";
}

function pair(own: 1 | 2 | 3 | null, o: 1 | 2 | 3 | null): string {
	return own === o ? "same" : "diff";
}

function plain(own: 1 | 2 | 3): string {
	if (own === 2) return "two";
	return own == 3 ? "three" : "other";
}

function plainPair(own: 1 | 2 | 3, o: 1 | 2 | 3): string {
	return own === o ? "same" : "diff";
}

function mixed(own: "a" | "b" | 1 | 2): string {
	if (typeof own === "number") return own === 2 ? "num-two" : "other";
	return own === "b" ? "str-b" : "other";
}

function mixedPair(own: "a" | "b" | 1 | 2, o: "a" | "b" | 1 | 2): string {
	if (typeof own === "number" && typeof o === "number") return own === o ? "same" : "diff";
	if (typeof own === "string" && typeof o === "string") return own === o ? "same" : "diff";
	return "diff";
}

console.log(`num=${num(1)} ${num(3)} ${num(null)}`);
console.log(`numNe=${numNe(1)} ${numNe(3)} ${numNe(null)}`);
console.log(`pair=${pair(1, 1)} ${pair(1, 2)} ${pair(null, null)} ${pair(null, 1)}`);
console.log(`plain=${plain(2)} ${plain(1)} ${plain(3)}`);
console.log(`plainPair=${plainPair(1, 1)} ${plainPair(1, 2)} ${plainPair(3, 3)}`);
console.log(`mixed=${mixed(2)} ${mixed("b")} ${mixed("a")}`);
console.log(`mixedPair=${mixedPair(1, 1)} ${mixedPair(1, 2)} ${mixedPair("a", 1)} ${mixedPair("b", "b")}`);
