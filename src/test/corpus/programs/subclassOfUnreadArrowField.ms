// @stdout: 20|21|22|23|24|3
// @exit: 0
// note: a subclass inherits a parent's arrow field whose type is inferred even when no code reads it: the field is settled when the subclass is checked. Before, its slot reached codegen unresolved and the C build stopped with "unresolved type (kind=48) reached codegen" (Raiser segfaulted).

const out: int32[] = [];

class Adder { base: int32 = 10; add = (x: int32): int32 => x + 1; }
class Derived extends Adder { extra: int32 = 20; }
const d = new Derived();
out.push(d.extra);

class Two { a = (x: int32): int32 => x + 1; b = (): int32 => { return 2; }; }
class TwoSub extends Two { extra: int32 = 21; }
out.push(new TwoSub().extra);

class Typed { add: (x: int32) => int32 = (x: int32): int32 => x + 1; }
class TypedSub extends Typed { extra: int32 = 22; }
out.push(new TypedSub().extra);

class L1 { f = (x: int32): int32 => x + 1; }
class L2 extends L1 { g = (x: int32): int32 => x + 2; }
class L3 extends L2 { extra: int32 = 23; }
out.push(new L3().extra);

class Gone { f = (x: int32): int32 => x + 1; }
class GoneSub extends Gone { extra: int32 = 24; }
new GoneSub();
out.push(new GoneSub().extra);

class R { f = (x: int32): int32 => x + 1; }
class RSub extends R { extra: int32 = 5; }
out.push(new RSub().f(2));
console.log(out.join("|"));
