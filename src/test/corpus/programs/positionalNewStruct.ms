// @stdout: 42 | s | 1 w
// @xfail(js): `new` on a struct is not emitted on JS (inbox 2026-10-21-new-on-a-struct-fails-on-js-and-the-raiser)
// @xfail(esm): same as js
// @xfail(raiser): the Raiser has no constructor for a struct (same card)
// note: positional `new` on a struct fills a generic instance's fields and converts into a union field, with and without an annotation. Before, C stopped with "reached codegen unlowered" or did not compile.
struct SB<T> { value: T; }
struct Prim { u: number | string; }
struct Tagged<T> { tag: int32; value: T; }

const g = new SB<number>(42);
const s: Prim = new Prim("s");
const t: Tagged<number | string> = new Tagged<number | string>(1, "w");
console.log(`${g.value} | ${s.u} | ${t.tag} ${t.value}`);
