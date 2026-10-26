// @stdout: a1 c3
// note: a T[N] local copy is a value on the Raiser: the copy hook fills a zeroed destination, so the source keeps its element. Second axis: the same through a function parameter copy.
function copyOf(a: string[2]): string[2] {
	let b: string[2] = a;
	b[0] = "c3";
	return b;
}

function locals(): void {
	const a: string[2] = ["a1", "b2"];
	let b: string[2] = a;
	b[0] = "c3";
	console.log(a[0] + " " + b[0]);
}

locals();
const src: string[2] = ["a1", "b2"];
const dst = copyOf(src);
console.log(src[0] + " " + dst[0]);
