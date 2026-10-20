// @exit: 1
// @stdout: before foo
// @xfail(danger): --danger drops the forced conversion check, so the wrong conversion reads Bar's memory as Foo's instead of stopping
// @xfail(raiser): the Raiser stops at the same conversion with exit 1, but its 'raiser runtime error: invalid object conversion: …' goes to stderr, which the raiser cell keeps apart from the compared output
// note: a class value cast into a distinct of another class is checked at run time as the cast into that class is: `new Bar() as DF` stops with "invalid object conversion" where it used to read Bar's memory as Foo's (a zero for `d` on C, a throw on JS). A subclass passes.

class Foo { c: string = "foo"; d: int32 = 3; }
class Sub extends Foo { e: int32 = 1; }
class Bar { c: string = "bar"; }
type DF = distinct Foo;

function fromFoo(o: Foo): DF { return o as DF; }
function fromBar(o: Bar): DF { return o as DF; }
console.log("before " + (fromFoo(new Sub()) as Foo).c);
console.log("after " + (fromBar(new Bar()) as Foo).d.toString());
