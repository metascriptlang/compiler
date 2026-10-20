// @stdout: Derived(y) < Base(x) < Root(r) | Tagged(tag) < Named(name) | Both(n) < Tagged(tag) < Named(name) < Sized(size) | IntBox(w) < 1@ Box(v) | 1 2 3 9
// @exit: 0
// note: getImpl of a struct or an interface hands a macro its bases as nodes bound where the declaration wrote them, as the reference's typed declaration carries its base as a symbol: a macro walks a base chain, a generic base included, through modules the call site never imported, and a namesake declared where the macro is called is not the base. The bases used to arrive only as text, so a macro looked them up at the call site.

import { chain } from "./describe";
import { Derived, Tagged, Both, IntBox } from "./shapes";

struct Base { z: int32; w: int32; }
struct Root { q: int32; }
interface Named { other: int32; }
struct Box { other: int32; }

const d: Derived = { r: 1, x: 2, y: 3 };
const local: Base = { z: 0, w: 0 };
const ib: IntBox = { v: 4, w: 5 };
console.log(`${chain(Derived)} | ${chain(Tagged)} | ${chain(Both)} | ${chain(IntBox)} | ${d.r} ${d.x} ${d.y + local.z} ${ib.v + ib.w}`);
