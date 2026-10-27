// @maxrcops: 60010
// @maxroots: 4
// @stdout: 30000
// note: a for-of over a T[] held by a const reads the array through the const; the rc ops and cycle-root registrations a copy into a temp would cost per loop stay off the ledger.

class Node {
	kids: Node[] = [];
	tag: string = "";
}

function tree(n: int32): Node {
	const root = new Node();
	for (let i: int32 = 0; i < n; i++) {
		const kid = new Node();
		kid.tag = "k";
		root.kids.push(kid);
	}
	return root;
}

const root = tree(3);
const kids = root.kids;
let total: int32 = 0;
for (let r: int32 = 0; r < 10000; r++) {
	for (const k of kids) { total = total + k.tag.length; }
}
console.log(String(total));
