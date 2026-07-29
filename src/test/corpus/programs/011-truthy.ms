function pick(x: number, on: boolean): number | null {
	if (on) { return x; }
	return null;
}

function main(): void {
	const zero = pick(0, true);
	const absent = pick(9, false);
	if (zero) { console.log("zero truthy"); } else { console.log("zero falsy"); }
	if (absent) { console.log("absent truthy"); } else { console.log("absent falsy"); }
	const s = zero ? "Z" : "z";
	console.log("ternary: " + s);
}
main();
