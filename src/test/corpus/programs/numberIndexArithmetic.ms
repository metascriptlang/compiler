// @stdout: read=dcc sum=60 xs=a,b,c,z ys=10,25,130,41 f32=c int=c
// An index that is a number computed at run time picks the element its value names, read and written.

function bump(ref slot: int32): void { slot += 100; }

function pick(xs: string[], n: number, one: number): string {
	return `${xs[n + one]}${xs[n * one]}${xs[(n + one) - one]}`;
}

function run(): void {
	const xs = ["a", "b", "c", "d"];
	const n: number = 2;
	const one: number = 1;
	const read = pick(xs, n, one);
	const ys: int32[] = [10, 20, 30, 40];
	const sum = ys[n + one] + ys[n - one];
	xs[n + one] = "z";
	ys[n - one] += 5;
	ys[n + one]++;
	bump(ys[n * one]);
	const f: float32 = 1;
	const fromF32 = xs[f + 1];
	const i: int32 = 1;
	const fromInt = xs[i + 1];
	console.log(`read=${read} sum=${sum} xs=${xs.join(",")} ys=${ys.join(",")} f32=${fromF32} int=${fromInt}`);
}
run();
