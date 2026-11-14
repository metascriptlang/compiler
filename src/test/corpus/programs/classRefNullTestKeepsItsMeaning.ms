// @stdout: forms: true false true false | false true false true
// @stdout: swapped: true false
// @stdout: walk: 6 3
// @stdout: ternary: none 7
// @stdout: and: false true
// @stdout: cleared: true
// note: a null test of a class reference reads the same in every spelling and position: ===, !==, ==, != on either side, as an if, a while, a ternary and an && operand, after the reference is set back to null.
class Link { n: int32 = 0; next: Link | null = null; constructor(n: int32) { this.n = n; } }

function forms(x: Link | null): string {
	let out = "";
	if (x === null) out += "true "; else out += "false ";
	if (x !== null) out += "true "; else out += "false ";
	if (x == null) out += "true "; else out += "false ";
	if (x != null) out += "true"; else out += "false";
	return out;
}

function sum(head: Link | null): int32 {
	let total: int32 = 0;
	let at = head;
	while (at !== null) {
		total += at.n;
		at = at.next;
	}
	return total;
}

function count(head: Link | null): int32 {
	let n: int32 = 0;
	for (let at = head; at != null; at = at.next) n += 1;
	return n;
}

function positive(x: Link | null): boolean {
	return x !== null && x.n > 0;
}

const a = new Link(1);
const b = new Link(2);
const c = new Link(3);
a.next = b;
b.next = c;
console.log(`forms: ${forms(null)} | ${forms(a)}`);
const none: Link | null = null;
console.log(`swapped: ${null === none ? true : false} ${null === a ? true : false}`);
console.log(`walk: ${sum(a)} ${count(a)}`);
console.log(`ternary: ${none !== null ? "some" : "none"} ${a !== null ? a.n + 6 : 0}`);
console.log(`and: ${positive(none)} ${positive(a)}`);
let held: Link | null = new Link(9);
held = null;
console.log(`cleared: ${held === null}`);
