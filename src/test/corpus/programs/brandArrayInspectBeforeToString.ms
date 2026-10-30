// @stdout: <Bx>
// @stdout: l <Bx>
// @stdout: text
// @stdout: <By>
// @stdout: { b: <Bx> }
type Bx = uint8[] & { __brand: "Bx" };
type By = uint8[] & { __brand: "By" };
function inspect(this b: Bx): string { return "<Bx>"; }
function toString(this b: Bx): string { return "text"; }
function inspect(this b: By): string { return "<By>"; }
const raw: uint8[] = [1, 2];
const a = raw as Bx;
const c = raw as By;
console.log(a);
console.log("l", a);
console.log(`${a}`);
console.log(c);
console.log({ b: a });
