// @stdout: tree=2047 live=same:3 twice=b read=hello-5 thrown=caught:2 swap=6|2 shared=2:2:2 derived=7:k:leaf init=fresh:rebound ctorStr=ab:ab self=ok:t-s-none more=fieldleaf=,ab1live,cap!,v3v3,tt,genv3,dldd,imp,ruru,argre,ns,rg=,nest

// A constructor takes ownership of the values written into its fields: a temporary or a
// last use moves in, a value still used after `new` is copied, and a field of the fresh
// object is never destroyed before its first write. A constructor that throws midway
// frees what it holds exactly once.
class Node {
	left: Node | null;
	right: Node | null;
	constructor(left: Node | null, right: Node | null) { this.left = left; this.right = right; }
}

function bottomUp(depth: int32): Node {
	if (depth > 0) return new Node(bottomUp(depth - 1), bottomUp(depth - 1));
	return new Node(null, null);
}

function count(n: Node): int32 {
	if (n.left == null) return 1;
	return 1 + count(n.left!) + count(n.right!);
}

class Leaf { name: string; constructor(name: string) { this.name = name; } }
class Holder { item: Leaf; n: int32; constructor(item: Leaf, n: int32) { this.item = item; this.n = n; } }

function liveArg(): string {
	const leaf = new Leaf("same");
	const h = new Holder(leaf, 3);
	return (h.item === leaf ? leaf.name : "diff") + ":" + h.n.toString();
}

class Twice { s: string; constructor(a: string, b: string) { this.s = a; this.s = b; } }

class Reader { len: int32; constructor(s: string) { this.len = s.length; } }

class Boom {
	held: Leaf;
	constructor(l: Leaf, bad: boolean) {
		this.held = l;
		if (bad) throw new Error("boom");
	}
}

function throwing(): string {
	let caught = 0;
	for (let i = 0; i < 2; i++) {
		try { const b = new Boom(new Leaf("x" + i.toString()), true); caught += b.held.name.length - 99; }
		catch (e) { caught += 1; }
	}
	return "caught:" + caught.toString();
}

class Pair { a: Leaf; b: Leaf; constructor(x: Leaf, y: Leaf) { this.a = y; this.b = x; } }

class Both { first: Leaf; second: Leaf; constructor(l: Leaf) { this.first = l; this.second = l; } }

class Base { tag: string; constructor(tag: string) { this.tag = tag; } }
class Derived extends Base {
	leaf: Leaf;
	constructor(tag: string, leaf: Leaf) { super(tag); this.leaf = leaf; }
}

class Fresh {
	box: Leaf = new Leaf("fresh");
	constructor(rebind: boolean, l: Leaf) { if (rebind) this.box = l; }
}

class StrBox { a: string; b: string; constructor(s: string) { this.a = s; this.b = s; } }

class SelfRead {
	next: SelfRead | null;
	tag: string;
	constructor(tag: string, other: SelfRead | null) {
		if (this.next == null) this.tag = tag + "-" + (other == null ? "none" : other.tag);
		this.next = other;
		this.tag = this.tag + "";
	}
}

class Wrap { child: Leaf; constructor(child: Leaf) { this.child = child; } }
class Multi {
	a: Leaf | null = null;
	b: Leaf | null = null;
	list: Leaf[];
	constructor(l: Leaf, flag: boolean) {
		if (flag) this.a = l; else this.b = l;
		this.list = [l];
	}
}
class Cb { f: () => string; constructor(f: () => string) { this.f = f; } }
class Str2 { a: string; constructor(s: string) { this.a = s; } }
interface Pt { tag: string; }
class PtBox { p: Pt; constructor(p: Pt) { this.p = p; } }
class Cell<T> { v: T; constructor(v: T) { this.v = v; } }
class Dflt { a: Leaf; b: string; constructor(a: Leaf, b: string = "dd") { this.a = a; this.b = b; } }
class Implicit extends Base {}
class Reuse extends Base {
	copy: string;
	constructor(t: string) { super(t); this.copy = t; }
}
class Reassign { f: Leaf; constructor(x: Leaf) { x = new Leaf("re"); this.f = x; } }
class Early { f: Leaf | null = null; constructor(l: Leaf, skip: boolean) { if (skip) return; this.f = l; } }
class Reg { f: Leaf; constructor(l: Leaf, into: Leaf[]) { this.f = l; into.push(l); } }

function more(): string {
	const out: string[] = [];
	const h = new Holder(new Leaf("fieldleaf"), 1);
	const w = new Wrap(h.item);
	out.push(w.child.name + (h.item === w.child ? "=" : "!"));
	const live = new Leaf("live");
	const m1 = new Multi(live, true);
	const m2 = new Multi(new Leaf("tmp"), false);
	out.push((m1.a === live ? "a" : "-") + (m2.b != null ? "b" : "-") + m1.list.length.toString() + live.name);
	const cap = "cap";
	const cb = new Cb(() => cap + "!");
	out.push(cb.f());
	const s = "v" + out.length.toString();
	const s2 = new Str2(s);
	out.push(s + s2.a);
	const pt: Pt = { tag: "t" };
	const pb = new PtBox(pt);
	out.push(pt.tag + pb.p.tag);
	const c1 = new Cell<Leaf>(new Leaf("gen"));
	const c2 = new Cell<string>(s);
	out.push(c1.v.name + c2.v);
	const d = new Dflt(new Leaf("dl"));
	out.push(d.a.name + d.b);
	out.push(new Implicit("imp").tag);
	const r = new Reuse("ru");
	out.push(r.tag + r.copy);
	const arg = new Leaf("arg");
	const re = new Reassign(arg);
	out.push(arg.name + re.f.name);
	const ea = new Early(arg, true);
	const eb = new Early(arg, false);
	out.push((ea.f == null ? "n" : "s") + (eb.f === arg ? "s" : "n"));
	const into: Leaf[] = [];
	const rg = new Reg(new Leaf("rg"), into);
	out.push(rg.f.name + (into[0] === rg.f ? "=" : "!"));
	out.push(new Holder(new Leaf("nest"), new Leaf("x").name.length).item.name);
	return out.join(",");
}

export function main(): void {
	const out: string[] = [];
	const t = bottomUp(10);
	out.push("tree=" + count(t).toString());
	out.push("live=" + liveArg());
	out.push("twice=" + new Twice("a", "b").s);
	out.push("read=" + "hello-" + new Reader("hello").len.toString());
	out.push("thrown=" + throwing());
	const l1 = new Leaf("l1");
	const l2 = new Leaf("longer");
	const p = new Pair(l1, l2);
	out.push("swap=" + p.a.name.length.toString() + "|" + p.b.name.length.toString());
	const b = new Both(new Leaf("bb"));
	out.push("shared=" + b.first.name.length.toString() + ":" + b.second.name.length.toString() + ":" + (b.first === b.second ? "2" : "0"));
	const d = new Derived("k", new Leaf("leaf"));
	out.push("derived=" + (d.tag.length + 6).toString() + ":" + d.tag + ":" + d.leaf.name);
	const f1 = new Fresh(false, l1);
	const f2 = new Fresh(true, l2);
	out.push("init=" + f1.box.name + ":" + (f2.box === l2 ? "rebound" : "other"));
	const sb = new StrBox("ab");
	out.push("ctorStr=" + sb.a + ":" + sb.b);
	const s0 = new SelfRead("s", null);
	const s1 = new SelfRead("t", s0);
	out.push("self=" + (s1.next === s0 ? "ok:" : "bad:") + s1.tag);
	out.push("more=" + more());
	console.log(out.join(" "));
}

main();
