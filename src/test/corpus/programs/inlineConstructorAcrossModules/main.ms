// note: an @inline constructor and an @inline static method are copied into every module that calls
// them (C), a parent's @inline constructor into the subclass constructor's copy. The copy keeps
// constructor semantics: overload signatures over one union implementation, field initializers, a
// private helper and variable of the defining module, a raise that leaves no object behind. Same
// output on every lane.
import { Sized, View, builtCount } from "./lib";
import { fromOther } from "./other";

const plain = new View(3, null);
console.log(plain.held, plain.store === null);
const fromArray = new Sized([1, 2, 3, 4]);
console.log(fromArray.label, fromArray.held);
const empty = new Sized();
console.log(empty.label, empty.held);
console.log(Sized.of(6).held, fromOther(5));
let caught = "";
try {
	new Sized(-2);
} catch (e) {
	caught = e.message;
}
console.log(caught, builtCount());
