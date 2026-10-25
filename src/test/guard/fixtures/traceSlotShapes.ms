class Node {
	next: Node | null = null;
	kids: Node[] = [];
	act: (() => int32) | null = null;
	val: int32 = 0;
}

let total: int32 = 0;
for (let i = 0; i < 20000; i++) {
	const a = new Node();
	const b = new Node();
	a.next = b;
	b.kids.push(a);
	const c = a;
	b.act = (): int32 => c.val;
	a.val = i as int32;
	total = (total + b.kids[0].val) % 1000003;
}
console.log(`total=${total}`);
