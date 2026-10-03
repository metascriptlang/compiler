// @stdout: n=5 s=row b=true i=-3 | 5 row | true -3 | cnt=15
function num(k: int32): number | string {
	return k == 0 ? 5 : "row";
}

function flag(k: int32): int32 | boolean {
	if (k == 0) return true;
	return -3;
}

function run(): void {
	const a = num(0);
	const b = num(1);
	const c = flag(0);
	const d = flag(1);
	console.log("n=" + a + " s=" + b + " b=" + c + ` i=${d}`, "|", String(a), String(b), "|", c, d, "| cnt=" + String(churn()));
}

function churn(): int32 {
	let total: int32 = 0;
	for (let i: int32 = 0; i < 3; i += 1) {
		const u = num(i % 2);
		const v = flag(i % 2);
		total += (String(u) + String(v)).length;
	}
	return total;
}

run();
