// @skip-js: C-only by design: onDestroy observes the destroys the DRC makes; JS frees nothing
// @stdout: dropped in destroy 2000 kept 0
// @stdout: kept past destroy 2000 kept 2000
// @stdout: freed 2000 kept 0
// note: an edge made to an object during its destroy is counted like any other: given up inside the destroy it frees nothing early, kept past the destroy it keeps the husk until it is given up, and giving it up unread frees the husk. Every object is destroyed once and freed once (the SAN cell's ledger).
class P {
	first: string;
	kids: Owned<C>[] = [];
	last: string;
	constructor(name: string) { this.first = name + "a"; this.last = name + "z"; }
}
class C { tag: int32 = 0; }
class H { ups: Unowned<P>[] = []; }
const h = new H();
let keep = false;
let destroyed = 0;
function onDestroy(this p: P): void {
	destroyed += 1;
	h.ups.push(p);
	if (!keep) h.ups.length = 0;
}
function make(i: int32): void {
	const p = new P("p" + i.toString());
	p.kids.push(new C());
}
for (let i: int32 = 0; i < 2000; i++) make(i);
console.log("dropped in destroy " + destroyed.toString() + " kept " + h.ups.length.toString());
keep = true;
for (let i: int32 = 0; i < 2000; i++) make(i);
console.log("kept past destroy " + (destroyed - 2000).toString() + " kept " + h.ups.length.toString());
h.ups.length = 0;
console.log("freed " + (destroyed - 2000).toString() + " kept " + h.ups.length.toString());
