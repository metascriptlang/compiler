// @stdout: 5 a n:8 s:b
// @stdout: 3 c 1,x
// @stdout: held 7
// @stdout: true y
// @stdout: sum 1 2
// @stdout: null 4 null 6 z
// @stdout: local null
// @stdout: tree 9
// @exit: 0
// note: an instance of a generic union alias is that union for every member it names: a local, an argument, a return, an array element and a class field each take an int32 or a string, typeof narrows it, two instances of one alias live side by side, a nullable alias instance takes null, and a recursive alias reaches the instance it is building. The instance's body used to carry only a stamped name, so it accepted none of its members.

import { Either, Opt, Both, Tree, describe, total } from "./mod";

const n: Either<int32> = 5;
const s: Either<int32> = "a";
console.log(`${n} ${s}`, describe(7), describe("b"));

function pick(flag: boolean): Either<int32> {
	return flag ? 3 : "c";
}
const items: Either<int32>[] = [1, "x"];
console.log(`${pick(true)} ${pick(false)}`, `${items[0]},${items[1]}`);

class Holder {
	v: Either<int32> = 7;
}
console.log("held", `${new Holder().v}`);

const b: Either<boolean> = true;
const bs: Either<boolean> = "y";
console.log(`${b} ${bs}`);

function sum(a: Either<int32>, c: Either<int32>): string {
	return `${a} ${c}`;
}
console.log("sum", sum(1, 2));

function opt(x: Opt<int32>): string { return `${x}`; }
function both(x: Both<int32>): string { return `${x}`; }
console.log(opt(null), opt(4), both(null), both(6), both("z"));

const local: Either<int32> | null = null;
console.log("local", `${local}`);

const tree: Tree<int32> = { kind: "node", l: { kind: "leaf", v: 4 }, r: { kind: "node", l: { kind: "leaf", v: 2 }, r: { kind: "leaf", v: 3 } } };
console.log("tree", `${total(tree)}`);
