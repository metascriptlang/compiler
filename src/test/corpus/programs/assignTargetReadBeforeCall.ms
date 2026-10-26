// @stdout: 5 0
// @stdout: 9 0
// @stdout: iv 7
// @stdout: 9 0
// note: an assignment reads its target (the object of a member, the array and index of an element) before the call on its right side runs, so a call that rebinds the object or moves the index cannot redirect the store; the third line puts the calls on both sides
class Cell { v: int32 = 0; }
let c = new Cell();
let k = 0;
let log = "";
const brr: int32[] = [0, 0, 0, 0, 0];
function swap(): int32 { c = new Cell(); return 5; }
function moveK(): int32 { k = 3; return 9; }
function idx(): int32 { log = log + "i"; return 1; }
function val(): int32 { log = log + "v"; return 7; }

function main(): void {
	const first = c;
	c.v = swap();
	console.log(first.v, c.v);
	brr[k] = moveK();
	console.log(brr[0], brr[3]);
	brr[idx()] = val();
	console.log(log, brr[1]);
	k = 0;
	brr[k + 1] = moveK();
	console.log(brr[1], brr[4]);
}
main();
