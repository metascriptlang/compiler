// @stdout: read ok
// @xfail(raiser): the Raiser VM runs no lifecycle hooks, so the hook counter stays 0
// @skip-js: onDestroy does not run on JS
// note: a child's onDestroy that only reads the parent it points at, without keeping it, runs clean. Siblings: onDestroyKeepingThisThroughChildHookStops

let reads = 0;

class Parent {
	c: Child | null = null;
	tag: int32 = 7;
	onDestroy(): void {
		const c = this.c;
		if (c != null) c.parent = this;
	}
}

class Child {
	parent: Parent | null = null;
	onDestroy(): void {
		const p = this.parent;
		if (p != null) reads += p.tag;
	}
}

function make(): void {
	const p = new Parent();
	p.c = new Child();
}

make();
console.log(reads == 7 ? "read ok" : "read " + reads);
