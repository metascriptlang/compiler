// @stdout: 3
// @stdout: 11
// @stdout: 3
// note: A for-of over a generator reads each step as an IteratorResult cell; the cell must be freed per step whether the item is a string, a number or a struct.

interface Box { n: int32; }

function* words(): Iterator<string> {
	yield "a";
	yield "bb";
}

function* boxes(): Iterator<Box> {
	yield { n: 4 };
	yield { n: 7 };
}

function* nums(): Iterator<int32> {
	yield 1;
	yield 2;
}

function run(): void {
	let total = 0;
	for (const w of words()) total = total + w.length;
	console.log(total);
	let sum = 0;
	for (const b of boxes()) sum = sum + b.n;
	console.log(sum);
	const kept: int32[] = [];
	for (const x of nums()) kept.push(x);
	console.log(kept.length + 1);
}
run();
