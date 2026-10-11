// @stdout: 0 2|3|1
// note: assigning `new Array(n)` over a binding reaches alias analysis with the constructor's
// type name as a child; a type names no location, so it aliases nothing. It used to stop the
// build with "alias analysis reached 'v' without its symbol".
struct Case { levels: Vec<int32>; }
let module: int32[] = new Array(1);
module = new Array(3);
function local(): string {
	let v: Vec<int32> = new Array(0);
	const before = v.length;
	v = new Array(2);
	return `${before} ${v.length}`;
}
function intoLiteral(): int32 {
	let expected: Vec<int32> = new Array(0);
	expected = new Array(0);
	expected.push(1);
	const c: Case = { levels: expected };
	return c.levels.length;
}
console.log([local(), `${module.length}`, `${intoLiteral()}`].join("|"));
