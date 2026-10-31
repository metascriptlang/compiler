// @stdout: head=2/2 plain=5/5 int=7 loop=200000
// note: a Borrow of one element returned through a Vec receiver stays a Borrow of that element; only a Borrow of the array itself is a view of the Vec.

function head(this a: number[]): Borrow<number> { return a[0]; }
function headOf<T>(this a: T[]): Borrow<T> { return a[0]; }

function main(): void {
	let v: Vec<float64> = [2.0, 1.0];
	let w: Vec<int32> = [7, 8];
	const arr: number[] = [5.0];
	let loop = 0;
	for (let i = 0; i < 100000; i += 1) {
		if (v.head() == 2.0) loop += 1;
		if (v.headOf() == 2.0) loop += 1;
	}
	console.log(`head=${v.head()}/${v.headOf()} plain=${arr.head()}/${arr.headOf()} int=${w.headOf()} loop=${loop}`);
}

main();
