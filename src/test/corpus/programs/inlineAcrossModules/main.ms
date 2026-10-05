// note: an @inline routine is copied into every module that calls it (C), and a call to it keeps
// call semantics: arguments evaluated once, a raise propagates, a private helper and a private
// variable of the defining module are reached from the copy, recursion works. The same calls
// through an operator overload and an extension. Same output on every lane.
import { twice, counted, label, halve, fact, viaLib, Span2, width } from "./lib";
import { fromOther } from "./other";

let evaluated: int32 = 0;

function next(): int32 {
	evaluated += 1;
	return evaluated * 10;
}

const a: Span2 = { low: 1, high: 5 };
const b: Span2 = { low: 2, high: 9 };
console.log(twice(next()), evaluated);
console.log(counted(4), counted(4));
console.log(label(7), fact(10));
console.log((a + b).width(), a.width(), viaLib(5));
console.log(fromOther(6));
let caught = "";
try {
	halve(7);
} catch (e) {
	caught = e.message;
}
console.log(halve(10), caught);
