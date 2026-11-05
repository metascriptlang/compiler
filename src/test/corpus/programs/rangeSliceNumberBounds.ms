// @stdout: array 2,3 len=2 inclusive 2,3,4 span 3,4 tail 4
// note: a range slice whose bounds are `number` values takes them as an index of type `number` is taken, on an array with `..` and `...` and on a Span; before, C added the double to the data pointer and did not compile.

function joined(v: Readonly<Span<uint8>>): string {
	let out = "";
	for (let i = 0; i < v.length; i++) out += (i > 0 ? "," : "") + v[i].toString();
	return out;
}

function run(xs: Readonly<uint8[]>): void {
	const from: number = 1;
	const to: number = 3;
	const view = xs[from..to];
	const whole: Readonly<Span<uint8>> = xs;
	const inner = whole[to - 1 .. to + 1];
	console.log(`array ${joined(view)} len=${view.length} inclusive ${joined(xs[from...to])} span ${joined(inner)} tail ${joined(inner[from..2])}`);
}

run([1, 2, 3, 4]);
