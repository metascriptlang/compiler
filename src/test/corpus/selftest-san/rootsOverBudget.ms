// @selftest-red root registrations
// @maxroots: 0
class Node {
	next: Node | null = null;
}

function link(): void {
	const a = new Node();
	const b = new Node();
	a.next = b;
	b.next = a;
	a.next = null;
}

link();
console.log("linked");
