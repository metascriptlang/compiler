// @stdout: x 2.5 row 5 y
function pick(k: int32): number | string | null {
	if (k == 0) return null;
	if (k == 1) return 2.5;
	return "row";
}

function pickInt(k: int32): int32 | null {
	if (k == 0) return null;
	return 5;
}

function run(): void {
	const a: number | string = pick(0) ?? "x";
	const b: number | string = pick(1) ?? "x";
	const c: number | string = pick(2) ?? "x";
	const d: int32 | string = pickInt(1) ?? "y";
	const e: int32 | string = pickInt(0) ?? "y";
	console.log(`${a as string} ${b as number} ${c as string} ${d as int32} ${e as string}`);
}

run();
