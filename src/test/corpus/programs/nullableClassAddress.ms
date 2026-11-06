// @stdout: none=null one=set field=set empty=null back=5
// note: a `B | null` held as a pointer converts to Ptr<void> as the pointer it is, null included; C stopped with an internal error before.

class B { n: int32 = 5; }
class Holder { b: B | null = null; }

function pick(b: B | null): B | null { return b; }

const nothing = null as Ptr<void>;
const one = new B();
const none = pick(null) as Ptr<void>;
const some = pick(one) as Ptr<void>;
const full = new Holder();
full.b = one;
const field = full.b as Ptr<void>;
const empty = new Holder().b as Ptr<void>;
const back = (some as B).n;
const text = (p: Ptr<void>): string => p == nothing ? "null" : "set";
console.log(`none=${text(none)} one=${text(some)} field=${text(field)} empty=${text(empty)} back=${back}`);
