// note: an @inline constructor of a generic class is copied into every module that builds an
// instance (C), and into a subclass constructor's copy through super; a static method of the
// generic class too. The copy keeps constructor semantics: a managed type argument, a variable of
// the defining module, a raise that leaves no object behind. Same output on every lane.
import { Holder, Names, builtCount } from "./lib";
import { fromOther } from "./other";

const words = new Holder<string>(["a", "b", "c"], 3);
console.log(words.items.join(""), words.length);
const names = new Names("n", 2);
console.log(names.label, names.items.join(","), names.length);
const pair = Holder.pair<string>("x", "y");
console.log(pair.items.join("+"), pair.length);
console.log(fromOther(3));
let caught = "";
try {
	new Holder<number>([], -1);
} catch (e) {
	caught = e.message;
}
console.log(caught, builtCount());
