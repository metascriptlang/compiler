// @stdout: plain=init:set:7 derived=base-done:skip guarded=3:4 loop=2 nested=n:inner
// A bare `return` in a constructor ends the body and `new` still yields the object: on a
// plain class, after `super(...)` in a derived class, inside a base constructor that
// `super(...)` runs, from inside a loop, and in a class whose field holds an object.
class Plain {
	f: string = "init";
	n: int32 = 7;
	constructor(skip: boolean) { if (skip) return; this.f = "set"; }
}

class Base {
	tag: string = "base";
	constructor(stop: boolean) { if (stop) return; this.tag = "never"; }
}
class Derived extends Base {
	mark: string = "";
	constructor(skip: boolean) {
		super(true);
		this.tag = this.tag + "-done";
		if (skip) return;
		this.mark = "full";
	}
}

class Guarded {
	n: int32;
	constructor(n: int32) {
		this.n = n;
		if (n > 2) { return; }
		this.n = 0;
	}
}

class Looper {
	hits: int32 = 0;
	constructor(limit: int32) {
		for (let i = 0; i < 10; i++) {
			if (i == limit) return;
			this.hits += 1;
		}
	}
}

class Inner { name: string; constructor(name: string) { this.name = name; } }
class Outer {
	child: Inner | null = null;
	constructor(c: Inner, keep: boolean) { if (!keep) return; this.child = c; }
}

export function main(): void {
	const out: string[] = [];
	const p1 = new Plain(true);
	const p2 = new Plain(false);
	out.push("plain=" + p1.f + ":" + p2.f + ":" + p1.n.toString());
	const d = new Derived(true);
	out.push("derived=" + d.tag + ":" + (d.mark == "" ? "skip" : d.mark));
	out.push("guarded=" + new Guarded(3).n.toString() + ":" + new Guarded(4).n.toString());
	out.push("loop=" + new Looper(2).hits.toString());
	const c = new Inner("inner");
	const o1 = new Outer(c, false);
	const o2 = new Outer(c, true);
	out.push("nested=" + (o1.child == null ? "n" : "s") + ":" + (o2.child != null ? o2.child.name : "-"));
	console.log(out.join(" "));
}

main();
