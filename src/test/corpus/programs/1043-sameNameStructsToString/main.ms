// @stdout: A(left) B(7) C3 A(left) B(7) C3 A(left)B(7)C3 A(left)B(7)C3
// @xfail(raiser): String(struct) yields an empty string on the Raiser VM, with or without the extension (`"[" + String(c) + "]"` prints `[]`)
// note: four modules each declare a `Cell`; three give theirs a `toString` extension and one gives none. Each rendering form (echo, String, concatenation, interpolation) is bound to the extension of the receiver's own declaration, and the type without one keeps its default dump instead of borrowing another module's routine.
import { makeA } from "./a";
import { makeB } from "./b";
import { Cell as CellC } from "./c";
import { makeD } from "./d";

const a = makeA();
const b = makeB();
const c = new CellC();
console.log(a, b, c, String(a), String(b), String(c), "" + a + b + c, `${a}${b}${c}`);
console.log(makeD());
