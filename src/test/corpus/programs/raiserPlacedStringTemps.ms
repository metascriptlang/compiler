// @stdout: 1 x
// @stdout: aA|a-b-c|hi 2
// note: a string a call produces and nothing else holds is released: the accumulated line of a multi-argument console.log, the tail an append of a code point builds, and the same tail inside a loop.

function main(): void {
	console.log(1, "x");
	let a = "a";
	a += fromCodePoint(65);
	let b = "";
	for (let i = 0; i < 3; i += 1) b += (i == 0 ? "" : "-") + fromCodePoint(97 + i);
	let c = "hi";
	c += fromCodePoint(32);
	c += (2).toString();
	console.log(a + "|" + b + "|" + c);
}
main();
