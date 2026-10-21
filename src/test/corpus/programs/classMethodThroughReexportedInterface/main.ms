// @stdout: a/3/1
// note: classMethodThroughImportedInterface with two type parameters declared in another order than the
// fields, reached through a re-exported interface: the owner's parameters keep their declared order.
import { Holder, makeHolder } from "./reexport";

function show(h: Holder): string { return h.pair.describe(); }

console.log(show(makeHolder()));
