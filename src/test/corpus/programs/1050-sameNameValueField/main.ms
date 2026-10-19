// @stdout: 3 4
// note: a value struct may hold a field of a same-named struct declared in another module; only a field of the declaring symbol itself is an infinite-size recursion.
import { Cell as CellA, makeCell } from "./a";

struct Cell { inner: CellA; n: number; }

const c: Cell = { inner: makeCell(3), n: 4 };
console.log(`${c.inner.x} ${c.n}`);
