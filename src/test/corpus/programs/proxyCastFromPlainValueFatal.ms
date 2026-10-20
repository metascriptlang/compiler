// @exit: 1
// @stdout: before x x foo
// @xfail(danger): --danger drops the forced conversion check, so the wrong conversion reads the plain value as a Proxy instead of stopping
// @xfail(raiser): the Raiser stops at the same conversion with exit 1, but its 'raiser runtime error: invalid object conversion: …' goes to stderr, which the raiser cell keeps apart from the compared output
// note: `as` into a distinct of a class checks the value's class at run time, as `as` into the class itself does. A Proxy is a distinct of its cell, so a Proxy cast back to its own type and a class cast to its own distinct pass, and a plain class value cast to a Proxy stops with "invalid object conversion" instead of being read as a Proxy (which crashed on C and threw on JS). An object literal cast the same way is proxyCastThroughConditionalAliasFatal.

interface C { c: string; }
class G<T> { get<K extends keyof T>(t: T, k: K): T[K] { return Reflect.get(t, k); } }
class Foo { c: string = "foo"; }
class Plain { c: string = "y"; }
type DF = distinct Foo;

const c: C = { c: "x" };
const p = new Proxy(c, new G<C>());
const same = p as Proxy<C, G<C> >;
const df = new Foo() as DF;
console.log("before " + p.c + " " + same.c + " " + (df as Foo).c);
const w = new Plain() as Proxy<C, G<C> >;
console.log("after " + w.c);
