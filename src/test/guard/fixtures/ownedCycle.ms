import { collectCycles } from "std/runtime";
let made = 0;
let gone = 0;
class N {
	kids: Owned<N>[] = [];
	constructor() { made += 1; }
	onDestroy(): void { gone += 1; }
}
function cycle(): void {
	const a = new N();
	const b = new N();
	a.kids.push(b);
	b.kids.push(a);
}
cycle();
collectCycles();
console.log("made", made, "gone", gone);
