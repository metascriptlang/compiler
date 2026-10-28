// @stdout: index 2
// @stdout: inner-read 2
// @stdout: twice 4
// @stdout: field 2
// @stdout: var-callee old7
// @stdout: field-callee old5
// @stdout: method old5
// @stdout: owned old
// @stdout: receiver 2
// @stdout: target 5 91
// @stdout: inner-target 50 71
// @stdout: after 90 new new1 2
// @stdout: local 2
class Box { items: int32[] = [1, 2]; tag: string = "old"; }
class Hook {
	f: (x: int32) => string;
	constructor(f: (x: int32) => string) { this.f = f; }
	call(x: int32): string { return this.f(x); }
}

let v: int32[] = [1, 2];
function growV(): int32 { v = [90, 91]; return 1; }

let w: int32[][] = [[1, 2], [3, 4]];
function growW(): int32 { w = [[70, 71], [72, 73]]; return 1; }

let box = new Box();
function growBox(): int32 {
	box = new Box();
	box.items = [90, 91];
	box.tag = "new";
	return 1;
}

function oldF(x: int32): string { return `old${x}`; }
function newF(x: int32): string { return `new${x}`; }
let ask: (x: int32) => string = oldF;
function swapAsk(): int32 { ask = newF; return 7; }

let hook = new Hook(oldF);
function swapHook(): int32 { hook = new Hook(newF); return 5; }

let owned: Box[] = [new Box()];
function growOwned(): int32 {
	owned = [new Box(), new Box()];
	owned[0].tag = "new";
	return 0;
}

console.log(`index ${v[growV()]}`);
console.log(`inner-read ${w[0][growW()]}`);
w = [[1, 2], [3, 4]];
console.log(`twice ${w[growW()][growW()]}`);
console.log(`field ${box.items[growBox()]}`);
console.log(`var-callee ${ask(swapAsk())}`);
console.log(`field-callee ${hook.f(swapHook())}`);
hook = new Hook(oldF);
console.log(`method ${hook.call(swapHook())}`);
console.log(`owned ${owned[growOwned()].tag}`);
v = [1, 2];
console.log(`receiver ${v.slice(growV())[0]}`);
v = [1, 2];
const before = v;
v[growV()] = 5;
console.log(`target ${before[1]} ${v[1]}`);
w = [[1, 2], [3, 4]];
const inner = w[0];
w[0][growW()] = 50;
console.log(`inner-target ${inner[1]} ${w[0][1]}`);
console.log(`after ${v[0]} ${box.tag} ${ask(1)} ${owned.length}`);

function local(): string {
	let a: int32[] = [1, 2];
	const g = (): int32 => { a = [90, 91]; return 1; };
	return `local ${a[g()]}`;
}
console.log(local());
