// @stdout: field a.kids=0
// @stdout: element rows[0]=0
// @stdout: global bag=0
// @stdout: destroyed 16 of 16
// @skip-js: onDestroy does not run on JS
// note: `x.push(f())` reads the array `x` names before it runs `f`, so when `f` replaces that array the push lands in the detached one, as TS does, and the detached array and every pushed item stay counted until they go; the receiver is a field, an array element and a global.

class Doc {
	value: string;
	kids: Doc[] = [];
	constructor(value: string) { this.value = value; }
}

let destroyed: int32 = 0;
function onDestroy(this d: Doc): void { destroyed += 1; }

function mkKid(a: Doc, i: int32): Doc {
	a.kids = [];
	return new Doc(`kid${i}`);
}
function viaField(): void {
	const a = new Doc("a");
	for (let i: int32 = 0; i < 5; i += 1) a.kids.push(mkKid(a, i));
	console.log(`field a.kids=${a.kids.length}`);
}

const rows: Doc[][] = [[]];
function mkRow(i: int32): Doc {
	rows[0] = [];
	return new Doc(`row${i}`);
}
function viaElement(): void {
	for (let i: int32 = 0; i < 5; i += 1) rows[0].push(mkRow(i));
	console.log(`element rows[0]=${rows[0].length}`);
}

let bag: Doc[] = [];
function mkBag(i: int32): Doc {
	bag = [];
	return new Doc(`bag${i}`);
}
function viaGlobal(): void {
	for (let i: int32 = 0; i < 5; i += 1) bag.push(mkBag(i));
	console.log(`global bag=${bag.length}`);
}

viaField();
viaElement();
viaGlobal();
console.log(`destroyed ${destroyed} of 16`);
