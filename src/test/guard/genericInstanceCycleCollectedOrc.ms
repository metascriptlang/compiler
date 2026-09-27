// nim-guard: under ORC a cycle that runs through a generic class instance is
// collected.
//
// Nim ccgtypes.nim genTypeInfoV2Impl sets traceImpl from genHook(attachedTrace)
// for every type, generic instances included; liftdestructors.nim produces the
// instance's =trace like any object's. NIM-REF CG-2 (ensureTypeInfoDef). Proven
// red on main c36ed0ab, whose instance TypeInfo got only name and destroyFn:
// Node alloc=600 destroy=0 under orc.
//
// RED MEANS a generic instance's TypeInfo lost its traceFn; run /trace-nim on
// ensureTypeInfoDef for the named instance.
//
// GUARD-BALANCE-ORC Node

class Box<T> {
	v: T | null;
	constructor() { this.v = null; }
}

class Pair<A, B> {
	a: A;
	b: B | null;
	constructor(a: A) { this.a = a; this.b = null; }
}

class Node {
	name: string;
	box: Box<Node>;
	kids: Map<string, Node>;
	pair: Pair<string, Node>;
	constructor(n: string) {
		this.name = n;
		this.box = new Box<Node>();
		this.kids = new Map<string, Node>();
		this.pair = new Pair<string, Node>(n);
	}
}

function viaBox(i: int32): int32 {
	const a = new Node("a" + i.toString());
	const b = new Node("b" + i.toString());
	a.box.v = b;
	b.box.v = a;
	return a.name.length as int32;
}

function viaMap(i: int32): int32 {
	const a = new Node("c" + i.toString());
	const b = new Node("d" + i.toString());
	a.kids.set("b", b);
	b.kids.set("a", a);
	return a.kids.size as int32;
}

function viaPair(i: int32): int32 {
	const a = new Node("e" + i.toString());
	const b = new Node("f" + i.toString());
	a.pair.b = b;
	b.pair.b = a;
	return b.pair.a.length as int32;
}

function main(): void {
	let s: int32 = 0;
	for (let i: int32 = 0; i < 100; i += 1) {
		s = s + viaBox(i) + viaMap(i) + viaPair(i);
	}
	console.log(s);
	console.log("GUARD-OK");
}
main();
