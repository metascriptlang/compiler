// @exit: 1
// @stdout: Error: onDestroy kept a reference to the Parent it destroys
// @xfail(raiser): the Raiser VM runs no lifecycle hooks, so onDestroy never runs and the program exits 0
// @skip-js: onDestroy does not run on JS
// note: a child's onDestroy that keeps the parent it points at in a global resurrects the parent while the parent's fields are being released, so the program stops naming the class. Siblings: onDestroyKeepingThisThroughGrandchildHookStops (one level deeper), onDestroyReadingParentInChildHookRuns (a read without keeping runs clean)

class Parent {
	c: Child | null = null;
	onDestroy(): void {
		const c = this.c;
		if (c != null) c.parent = this;
	}
}

class Child {
	parent: Parent | null = null;
	onDestroy(): void {
		kept = this.parent;
	}
}

let kept: Parent | null = null;

function make(): void {
	const p = new Parent();
	p.c = new Child();
}

make();
console.log("unreachable");
