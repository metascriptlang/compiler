// @stdout: null
// @stdout: null
// @stdout: <null>
// @stdout: {"n":1}
class Box { n: number = 1; }
function show<T>(v: T): string { return `${v}`; }
function inFunction(): string {
	const x: Box | null = null;
	return `<${x}>`;
}
console.log(show<Box | null>(null));
console.log(show<string | null>(null));
console.log(inFunction());
console.log(show<Box | null>(new Box()));
