function loud(label: string, v: float64): float64 {
	console.log(label);
	return v;
}

console.log("helper a");
export const base: float64 = loud("helper base", 7);
console.log("helper b");
