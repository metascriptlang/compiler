// @stdout: array 40 1
// @stdout: write 7 1
// @stdout: compound 33 1
// @stdout: update 32 1
// @stdout: span 50 1
// @stdout: spanCompound 53 1
// @stdout: wide 40 1
// @stdout: wideUpdate 41 1
// @exit: 0
// note: a checked element access reads a computed index once, whatever the container or the index width, so a side-effecting index is not repeated by the bound test.
let calls = 0;

function next(): int32 {
	calls++;
	return 2;
}

function nextWide(): int64 {
	calls++;
	return 2 as int64;
}

function main(): void {
	const a: int32[] = [10, 20, 30, 40];
	const base: int32[] = [10, 20, 30, 40, 50];
	const s: Span<int32> = base[1..5];
	const b: int32[] = [10, 20, 30, 40];
	calls = 0;
	const r = a[next() + 1];
	console.log(`array ${r} ${calls}`);
	calls = 0;
	a[next() + 1] = 7;
	console.log(`write ${a[3]} ${calls}`);
	calls = 0;
	a[next() + 1] += 26;
	console.log(`compound ${a[3]} ${calls}`);
	calls = 0;
	a[next() + 1]--;
	console.log(`update ${a[3]} ${calls}`);
	calls = 0;
	const v = s[next() + 1];
	console.log(`span ${v} ${calls}`);
	calls = 0;
	s[next() + 1] += 3;
	console.log(`spanCompound ${s[3]} ${calls}`);
	calls = 0;
	const w = b[nextWide() + (1 as int64)];
	console.log(`wide ${w} ${calls}`);
	calls = 0;
	b[nextWide() + (1 as int64)]++;
	console.log(`wideUpdate ${b[3]} ${calls}`);
}

main();
