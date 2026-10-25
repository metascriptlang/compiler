// @maxrss: 30
// @stdout: borrow-return-by-value-first 5088890 5088890 599994 9088889
struct Row { a: string; b: int32; }
function firstA(r: Row): Borrow<string> { return r.a; }
function self(s: string): Borrow<string> { return s; }
function num(n: int32): Borrow<int32> { return n; }
function mk(k: int32): Row { return { a: `made-${k}-padding-padding`, b: k }; }
function mkS(k: int32): string { return `str-${k}-padding-padding`; }
let fromStruct = 0;
let fromString = 0;
let fromScalar = 0;
let fromTemporary = 0;
for (let k = 0; k < 200000; k += 1) {
	const r: Row = { a: `row-${k}-padding-padding`, b: k % 5 };
	const n: int32 = k % 7;
	fromStruct += firstA(r).length;
	fromString += self(mkS(k)).length;
	fromScalar += num(n);
	fromTemporary += firstA(mk(k)).length + firstA({ a: "lit-padding", b: 1 }).length + num(k % 3) + self("literal").length;
}
console.log("borrow-return-by-value-first", fromStruct, fromString, fromScalar, fromTemporary);
