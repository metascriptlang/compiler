// @stdout: 9
// note: a method of a generic class reached only through an interface of another module takes the class's
// type parameters as its owner's; collecting them walked the receiver's fields, which never ended on a class
// whose fields refer back to themselves (Link.next).
import { Holder, makeHolder } from "./holder";

function count(h: Holder): number { return h.grid.length(); }

console.log(count(makeHolder()));
