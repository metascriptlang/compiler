// @exit: 1
// @stdout: Error: onDestroy kept a reference to the Root it destroys
// @xfail(raiser): the Raiser VM runs no lifecycle hooks, so onDestroy never runs and the program exits 0
// @skip-js: onDestroy does not run on JS
// note: the grandchild's onDestroy keeps the root two links up in a global while the root's fields are being released, so the program stops naming the class. Sibling: onDestroyKeepingThisThroughChildHookStops

class Root {
	mid: Mid | null = null;
	onDestroy(): void {
		const m = this.mid;
		if (m != null && m.leaf != null) m.leaf.root = this;
	}
}

class Mid {
	leaf: Leaf | null = null;
}

class Leaf {
	root: Root | null = null;
	onDestroy(): void {
		kept = this.root;
	}
}

let kept: Root | null = null;

function make(): void {
	const r = new Root();
	r.mid = new Mid();
	r.mid.leaf = new Leaf();
}

make();
console.log("unreachable");
