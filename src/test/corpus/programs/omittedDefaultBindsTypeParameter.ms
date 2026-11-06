// @stdout: number:1 string:tail | string:x string:tail | boolean:true number:7
// @exit: 0

function show<T>(t: T): string {
	return `${typeof t}:${t}`;
}

function describe<P, A>(p: P, a: A = "tail"): string {
	return `${show(p)} ${show(a)}`;
}

console.log(describe(1), "|", describe("x"), "|", describe(true, 7));
