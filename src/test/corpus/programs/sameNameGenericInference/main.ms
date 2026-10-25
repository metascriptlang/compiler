// @stdout: box-or|cell-or|box-or|cell-or
// note: a generic base is matched by its declaration, not its spelling: `b.Box<string>` passed
// where `a.Box<T> | T` is expected binds T to b's Box, as an unrelated class would. The checker
// used to unify the two Boxes by name and refuse the class; the struct passed it and C refused.
import { Box as ABox, Cell as ACell, boxOr, cellOr } from "./a";
import { Box, Cell } from "./b";

const out: string[] = [];
out.push(boxOr(new Box<string>("s")));
const cell: Cell<string> = { w: "s" };
out.push(cellOr(cell));
out.push(boxOr(new ABox<string>("s")));
const own: ACell<string> = { v: "s" };
out.push(cellOr(own));
console.log(out.join("|"));
