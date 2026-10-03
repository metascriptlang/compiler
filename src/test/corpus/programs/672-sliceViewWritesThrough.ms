// @stdout: 4 319 312 0 0 532 317
function bump(xs: Span<int32>): void {
	for (let i = 0; i < xs.length; i++) xs[i] += 100;
}

function sum(xs: Span<int32>): int32 {
	let total = 0;
	for (const x of xs) total += x;
	return total;
}

function tail(xs: Span<int32>): int32 {
	return sum(xs[1..xs.length]);
}

function byteSum(view: Span<char>): int32 {
	let total = 0;
	for (let i = 0; i < view.length; i++) total += view[i] as int32;
	return total;
}

function run(): void {
	const dyn: int32[] = [1, 2, 3, 4, 5];
	let fixed: int32[4] = [10, 20, 30, 40];
	bump(dyn[1..3]);
	bump(fixed[2...3]);
	const v: Span<int32> = dyn[1..5];
	v[0] = 7;
	bump(v[2..4]);
	console.log(`${dyn[0]} ${dyn[1]} ${dyn[2]} ${dyn[3]} ${dyn[4]}`);
	console.log(`${fixed[0]} ${fixed[1]} ${fixed[2]} ${fixed[3]}`);
	const s = "hello";
	console.log(`${v.length} ${sum(v)} ${tail(v)} ${sum(dyn[5..5])} ${sum(dyn[9..9])} ${byteSum(s)} ${byteSum(s[1..4])}`);
}

run();
