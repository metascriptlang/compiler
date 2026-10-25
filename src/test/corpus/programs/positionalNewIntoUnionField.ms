// @stdout: 5 | q | 6 | z | t 9 | k
// note: positional `new` on a class without a constructor converts each argument into its field's type as an assignment does, a union of objects or of primitives, through a generic instance and under an annotation. Before, C did not compile and JS lost the object member.
type U = { a: number } | { b: string };
class Box { u: U; }
class Prim { u: number | string; }
class Gen<T> { tag: string; u: T; }

const first = new Box({ a: 5 });
const second = new Box({ b: "q" });
const num = new Prim(6);
const gen = new Gen<number | string>("x", "z");
const obj = new Gen<U>("t", { a: 9 });
const typed: Prim = new Prim("k");
console.log(`${(first.u as { a: number }).a} | ${(second.u as { b: string }).b} | ${num.u} | ${gen.u} | ${obj.tag} ${(obj.u as { a: number }).a} | ${typed.u}`);
