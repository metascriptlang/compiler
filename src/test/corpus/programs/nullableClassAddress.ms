// @stdout: none=null one=set back=5
// @xfail(raiser): a function returning a class parameter cast to Ptr<void> leaks the object (inbox 2026-11-07-raiser-returned-class-to-ptr-cast-leaks-object)
// note: a `B | null` held as a pointer converts to Ptr<void> as the pointer it is, null included; C stopped with an internal error before.

class B { n: int32 = 5; }

function addr(b: B | null): Ptr<void> { return b as Ptr<void>; }

const nothing = null as Ptr<void>;
const one = new B();
const none = addr(null) == nothing ? "null" : "set";
const some = addr(one) == nothing ? "null" : "set";
const back = (addr(one) as B).n;
console.log(`none=${none} one=${some} back=${back}`);
