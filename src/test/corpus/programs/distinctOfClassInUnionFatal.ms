// @exit: 1
// @stdout: before foo
// @xfail(danger): --danger drops the forced conversion check, so the Bar is read as a Foo instead of stopping
// @xfail(raiser): the Raiser stops at the same conversion with exit 1, but its 'raiser runtime error: invalid object conversion: …' goes to stderr, which the raiser cell keeps apart from the compared output
// note: `o as DF` out of `Foo | Bar` checks the value against Foo, as `o as Foo` does, so a Bar stops with "invalid object conversion: Bar is not Foo"

class Foo { c: string = "foo"; d: int32 = 3; }
class Bar { c: string = "bar"; }
type DF = distinct Foo;

function pick(o: Foo | Bar): DF { return o as DF; }

console.log("before " + (pick(new Foo()) as Foo).c);
console.log("after " + (pick(new Bar()) as Foo).c);
