// guard: under ORC a garbage cycle whose members each own a 200 000-link list is
// collected, and the collector frees those lists without overflowing the native stack.
//
// RED MEANS the collector's destroy of a cycle member recursed down an owned list
// (a crash), or a list freed through the drain was left behind (Link imbalance).
//
// GUARD-BALANCE Link
// GUARD-BALANCE Pair

class Link {
	next: Link | null = null;
}

class Pair {
	other: Pair | null = null;
	chain: Link | null = null;
}

function chain(n: int32): Link {
	let head = new Link();
	for (let i: int32 = 1; i < n; i++) {
		const link = new Link();
		link.next = head;
		head = link;
	}
	return head;
}

function pair(n: int32): void {
	const a = new Pair();
	const b = new Pair();
	a.chain = chain(n);
	b.chain = chain(n);
	a.other = b;
	b.other = a;
}

function main(): void {
	for (let i: int32 = 0; i < 2; i++) pair(200000);
	console.log("GUARD-OK");
}
main();
