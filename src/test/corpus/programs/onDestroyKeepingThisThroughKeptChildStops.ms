// @exit: 1
// @stdout: linked
// @stdout: Error: onDestroy kept a reference to the Parent it destroys
// @xfail(raiser): the Raiser VM runs no lifecycle hooks, so onDestroy never runs and the program exits 0
// @skip-js: onDestroy does not run on JS
// note: an onDestroy that links `this` into its child and also keeps that child in a global leaves the child pointing at the freed object once the object's fields are released, so the program stops naming the class. Sibling: onDestroyLinkingThisIntoOwnedChildRuns (the child goes with the object)

class Child {
	parent: Parent | null = null;
}

let kept: Child | null = null;

class Parent {
	c: Child | null = null;
	onDestroy(): void {
		kept = this.c;
		if (this.c != null) this.c.parent = this;
	}
}

function run(): void {
	const p = new Parent();
	p.c = new Child();
	console.log("linked");
}

run();
console.log("unreachable");
