// @stdout: field 1 elem 1
// @ledger-slack(Holder): 1
// @ledger-slack(Box): 2
// @ledger-slack(msRefArrayRefCell): 1
// @xfail(raiser): the Raiser VM has no host function msStringSubstring
// note: a local that reads through a module-level variable is an owned copy, never a borrow. A callee can replace the global while the local is alive; the local used to borrow and read the freed object.

class Box { n: int32; constructor(n: int32) { this.n = n; } }
class Holder { child: Box; constructor(n: int32) { this.child = new Box(n); } }

let g = new Holder(1);
let gs: Box[] = [new Box(1)];

function resetHolder(): void { g = new Holder(2); }
function resetFirst(): void { gs[0] = new Box(2); }

function fieldOfGlobal(): string {
	const c = g.child;
	resetHolder();
	const reuse = new Box(99);
	return "field " + String(c.n) + " " + String(reuse.n);
}

function elementOfGlobal(): string {
	const b = gs[0];
	resetFirst();
	const reuse = new Box(98);
	return "elem " + String(b.n) + " " + String(reuse.n);
}

const a = fieldOfGlobal();
const b = elementOfGlobal();
console.log(a.substring(0, 7) + " " + b.substring(0, 6));
console.log(a);
console.log(b);
