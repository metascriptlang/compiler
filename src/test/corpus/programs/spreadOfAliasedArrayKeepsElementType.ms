// @stdout: 1.5,2,9 1.5,2,9 9,2.5 0.5,9 a,z 1.25,2.75
// @exit: 0
// note: an array literal spreading a transparent alias of an array takes the alias's element type, one and two alias levels deep, a generic array alias, a string element, and a literal of spreads only.

type Brand<T> = T;
type List<T> = T[];
function b1(xs: Brand<number[]>): string { const more = [...xs, 9]; return more.join(","); }
function b2(xs: number[]): string { const more = [...xs, 9]; return more.join(","); }
function b3(xs: Brand<Brand<number[]>>): string { const more = [9, ...xs]; return more.join(","); }
function b4(xs: List<number>): string { const more = [...xs, 9]; return more.join(","); }
function b5(xs: Brand<string[]>): string { const more = [...xs, "z"]; return more.join(","); }
function b6(xs: Brand<number[]>, ys: Brand<number[]>): string { const more = [...xs, ...ys]; return more.join(","); }
console.log(`${b1([1.5, 2])} ${b2([1.5, 2])} ${b3([2.5])} ${b4([0.5])} ${b5(["a"])} ${b6([1.25], [2.75])}`);
