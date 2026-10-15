function load(n: int32): int32 {
	if (n > 0) throw new Error("b failed");
	return n;
}
console.log("b starts");
export const value = load(1);
console.log("b ends");
