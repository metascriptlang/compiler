// @stdout: a=3 b=4 c=1.5 d=w e=true
// note: an `infer` type parameter is its own declaration: it shadows an outer parameter of the same name,
// two `infer A` in one clause are one parameter, and a nested conditional infers again.
interface Box<V> { v: V; }
type Unwrap<T> = T extends Box<infer U> ? U : T;
type Shadow<T> = T extends Box<infer T> ? T : string;
type Both<T> = T extends [infer A, infer A] ? A : boolean;
type Deep<T> = T extends Box<infer U> ? (U extends Box<infer W> ? W : U) : T;
function show<T>(label: string, v: T): string { return `${label}=${v}`; }
const a: Unwrap<Box<int32>> = 3;
const b: Shadow<Box<int32>> = 4;
const c: Both<[float64, float64]> = 1.5;
const d: Deep<Box<Box<string>>> = "w";
const e: Unwrap<boolean> = true;
console.log(show("a", a), show("b", b), show("c", c), show("d", d), show("e", e));
