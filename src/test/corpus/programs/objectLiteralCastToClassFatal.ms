// @exit: 1
// @stdout: before
// @xfail(danger): --danger drops the forced conversion check, so the literal is read as a Foo instead of stopping
// @xfail(raiser): the Raiser stops at the same conversion with exit 1, but its 'raiser runtime error: invalid object conversion: …' goes to stderr, which the raiser cell keeps apart from the compared output
// note: an object literal has no class, so a failed conversion names it `Object` on every backend, also when it was built as an interface that extends the one it is held as

interface C { c: string; }
interface D extends C { d: string; }
class Foo { c: string = "foo"; }

const d: D = { c: "x", d: "y" };
const c: C = d;
console.log("before");
const f = c as Foo;
console.log("after " + f.c);
