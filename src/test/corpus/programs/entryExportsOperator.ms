// @stdout: less=true,false neg=-2
struct V { x: int32; }
export function `<`(a: V, b: V): boolean { return a.x < b.x; }
export function `-`(a: V): V { return { x: -a.x }; }
const one: V = { x: 1 };
const two: V = { x: 2 };
const neg = -two;
console.log(`less=${one < two},${two < one} neg=${neg.x}`);
