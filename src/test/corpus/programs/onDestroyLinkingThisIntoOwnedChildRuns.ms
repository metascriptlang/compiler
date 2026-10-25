// @skip-js: onDestroy does not run on JS
// @xfail(raiser): the Raiser VM runs no lifecycle hooks and frees a 1 000 000-link list recursively
// @stdout: one level done
// @stdout: two levels done
// @stdout: chain 50 done 50 hooks
// @stdout: chain 1000000 done 1000000 hooks
// note: an onDestroy that links `this` into a child the object alone owns is released with that child, so the object is freed with nothing left pointing at it and the program runs on; the same holds two levels down and on a 1 000 000-link list whose drop crosses the stack bound before the child is released. Sibling: onDestroyKeepingThisThroughKeptChildStops (the child outlives the object)

class Child {
	parent: Parent | null = null;
	c: Child | null = null;
	link: Link | null = null;
}

class Parent {
	c: Child | null = null;
	deep: boolean = false;
	onDestroy(): void {
		if (this.c == null) return;
		if (this.deep && this.c.c != null) this.c.c.parent = this;
		else this.c.parent = this;
	}
}

class Link {
	c: Child | null = null;
	next: Link | null = null;
}

let hooks = 0;
function onDestroy(this l: Link): void {
	hooks += 1;
	if (l.c != null) l.c.link = l;
}

function oneLevel(): void {
	const p = new Parent();
	p.c = new Child();
}

function twoLevels(): void {
	const p = new Parent();
	p.deep = true;
	p.c = new Child();
	p.c.c = new Child();
}

function chain(n: number): void {
	let h: Link | null = null;
	for (let i = 0; i < n; i++) {
		const x = new Link();
		x.c = new Child();
		x.next = h;
		h = x;
	}
	hooks = 0;
	h = null;
	console.log(`chain ${n} done ${hooks} hooks`);
}

oneLevel();
console.log("one level done");
twoLevels();
console.log("two levels done");
chain(50);
chain(1000000);
