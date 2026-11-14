// @stdout: same: true false | true false
// @stdout: equal fields: false true | false true
// @stdout: base and derived: true false
// @stdout: nullable: true false false true
// @stdout: loop: 2
// note: === and !== on class instances compare identity, as conditions and as values, whatever their fields hold, through a base-typed reference and a nullable one.
class Cell { v: int32 = 0; constructor(v: int32) { this.v = v; } }
class Big extends Cell { w: int32 = 1; }

function ifSame(a: Cell, b: Cell): boolean {
	if (a === b) return true;
	return false;
}
function ifDiffers(a: Cell, b: Cell): boolean {
	if (a !== b) return true;
	return false;
}
function ifSameMaybe(a: Cell | null, b: Cell | null): boolean {
	if (a === b) return true;
	return false;
}

const one = new Cell(1);
const twin = new Cell(1);
console.log(`same: ${ifSame(one, one)} ${ifDiffers(one, one)} | ${one === one} ${one !== one}`);
console.log(`equal fields: ${ifSame(one, twin)} ${ifDiffers(one, twin)} | ${one === twin} ${one !== twin}`);
const big = new Big(2);
const asBase: Cell = big;
console.log(`base and derived: ${ifSame(asBase, big)} ${ifSame(asBase, one)}`);
const none: Cell | null = null;
console.log(`nullable: ${ifSameMaybe(none, null)} ${ifSameMaybe(none, one)} ${ifSameMaybe(one, null)} ${ifSameMaybe(one, one)}`);
const cells: Cell[] = [one, twin, one];
let hits: int32 = 0;
for (const c of cells) {
	if (c === one) hits += 1;
}
console.log(`loop: ${hits}`);
