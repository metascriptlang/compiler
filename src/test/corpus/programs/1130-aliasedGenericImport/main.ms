// @stdout: 1 5 6 7 9 8|other 4
// note: a generic class or struct imported under another name is the declaration it names: its
// instances share the declaring module's struct and methods, and contextual `new` infers through
// it. The alias used to become the instance's name, so `C<int32>` matched nothing declared as
// `Cell<T>`. Two same-named generics imported under two aliases stay two types.
import { Cell as C, Pt as P, idOf } from "./shapes";
import { Cell as OtherCell } from "./other";

function id2<T>(x: T): T { return x; }

const xs: C<int32>[] = [new C<int32>(1)];
const r: int32 = id2<C<int32>>(new C<int32>(5)).get();
const q: int32 = idOf<C<int32>>(new C<int32>(6)).get();
const p: P<int32> = { x: 3, y: 4 };
const ps: P<int32>[] = [p, id2<P<int32>>(p)];
const m = new Map<string, C<int32>>();
m.set("k", new C<int32>(9));
const got = m.get("k");
const inferred: C<int32> = new C(8);
const other: OtherCell<int32> = new OtherCell(4);
console.log([`${xs[0].get()} ${r} ${q} ${ps[1].x + ps[0].y} ${got != null ? got.get() : -1} ${inferred.get()}`, `${other.tag} ${other.w}`].join("|"));
