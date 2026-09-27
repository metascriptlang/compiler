// @stdout: nullable xxx true 50% 3 12.5 50% string number

function show(value: float32 | string | null): string {
	if (value === null) return "none";
	if (typeof value === "string") return value;
	return (value as float32).toString();
}

function run(): void {
	let text: string | null = "x".repeat(3);
	const saved = text;
	text = null;
	let first: float32 | string | null = "50" + "%";
	let second: float32 | string | null = first;
	second = 3.0;
	let assigned: float32 | string | null = 12.5;
	const numeric = show(assigned);
	assigned = "50%";
	const stringKind = typeof first;
	const numberKind = typeof second;
	console.log(`nullable ${saved !== null ? saved : "missing"} ${text === null} ${show(first)} ${show(second)} ${numeric} ${show(assigned)} ${stringKind} ${numberKind}`);
}
run();
