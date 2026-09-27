// @exit: 1
// @stdout: narrowed
// @xfail(danger): --danger elides the variant field check, so the read of the other variant is undefined behaviour
// @xfail(raiser): Raiser has no variant field check; the read yields nil
// @xfail(js): node reports the uncaught variant defect with its own trace on stderr, where C prints 'Error: field ...'; C also makes the defect fatal where JS lets it be caught
// @xfail(esm): node reports the uncaught variant defect with its own trace on stderr, where C prints 'Error: field ...'; C also makes the defect fatal where JS lets it be caught
enum K { Num, Str }
type D = match (kind: K) {
	K.Num => { value: float64 },
	K.Str => { text: string },
};
class Box { d: D = { kind: K.Str, text: "hello" }; }
function setNum(x: Box): void {
	x.d = { kind: K.Num, value: 12345.5 };
}
function run(): void {
	const b = new Box();
	if (b.d.kind == K.Str) {
		console.log("narrowed");
		setNum(b);
		console.log(b.d.text);
	}
	console.log("unreachable");
}
run();
