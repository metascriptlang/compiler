// note: generics-mono-15. A module-private type whose name matches the caller's type got its TypeInfo emitted under the caller's name when a generic instance over the caller's type landed in the defining module's TU: the lifter's TypeInfo var carried only the bare name and codegen resolved it through the TU's name cache, so both TUs defined Item__<main>TypeInfo (lld-link: duplicate symbol). Fix: the lifter carries the hook base C name on the TypeInfo var and codegen names the symbol from it. Two shapes: an interface (Item) and a class (Tag).

import { wrap, libSum } from "./typeInfoSameNameLib";

interface Item { name: string; }

class Tag {
	label: string;
	constructor(l: string) { this.label = l; }
}

function mk(s: string, i: int32): string { return s + i.toString(); }

function run(): void {
	const it: Item = { name: mk("hello", 1) };
	const items = wrap(it);
	const tags = wrap(new Tag(mk("tag", 2)));
	console.log(items[0].name);
	console.log(tags[0].label);
	console.log(libSum());
}
run();
