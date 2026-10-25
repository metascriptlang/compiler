// @stdout: 1 2 3 4 5|two three four five six|false false false false|true true|1.5 user
// note: a user class is named by its declaration, whatever it is called. A class spelled like a
// compiler-made type (`a__b`, `Maybe_*`, `msTuple_*`, `msUnion_*`, a `__` generic) used to share
// one C struct with its namesake in another module, or with the compiler's own nullable struct.
import { libTypes, libValues } from "./lib";

class a__b { s: string = "two"; }
class Maybe_x { s: string = "three"; }
class msTuple_z { s: string = "four"; }
class msUnion_u { s: string = "five"; }
class g__x<T> { s: string = "six"; v: T; constructor(v: T) { this.v = v; } }
class Maybe_p17 { s: string = "user"; }

const mine = `${new a__b().s} ${new Maybe_x().s} ${new msTuple_z().s} ${new msUnion_u().s} ${new g__x<int32>(0).s}`;
const n: float64 | null = 1.5;
console.log(`${libValues()}|${mine}|${libTypes(new a__b())}|${new a__b() instanceof a__b} ${new Maybe_x() instanceof Maybe_x}|${n} ${new Maybe_p17().s}`);
