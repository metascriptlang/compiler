// @stdout: 17 3 30 4 16 12 33 44 3 50 32
function sumSpan(xs: Span<int32>): int32 {
	let total = 0;
	for (const x of xs) total += x;
	return total;
}

function bumpSpan(xs: Span<int32>, i: int32): void {
	xs[i] += 10;
	xs[i]++;
}

function pick(rows: int32[][]): int32[] {
	return rows[1];
}

function run(): void {
	const dyn: int32[] = [1, 2, 3];
	let fixed: int32[3] = [4, 5, 6];
	const grid: int32[][] = [[1, 2], [3, 4]];
	let i = 2;
	dyn[i] = 30;
	dyn[0] += 5;
	dyn[1]++;
	fixed[i] *= 2;
	bumpSpan(dyn, 0);
	bumpSpan(fixed, 1);
	grid[1][0] = 33;
	pick(grid)[1] = 44;
	const j: int64 = 1 as int64;
	console.log(`${dyn[0]} ${dyn[1]} ${dyn[2]} ${fixed[0]} ${fixed[1]} ${fixed[2]} ${grid[1][0]} ${grid[1][1]} ${dyn[j]} ${sumSpan(dyn)} ${sumSpan(fixed)}`);
}

run();
