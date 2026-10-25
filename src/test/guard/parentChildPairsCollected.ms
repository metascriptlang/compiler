// nim-guard: the one memory mode collects cycles. 100 000 parent/child pairs, each linked both
// ways and dropped, are all destroyed by exit.
// Proven red on 8338664ce built with --gc=drc, the mode every lane ran before the collector was
// always linked: Parent alloc=100000 destroy=0, Child alloc=100000 destroy=0.
//
// RED MEANS a default build stopped linking or running the cycle collector; run /trace-nim on
// the named type.
//
// GUARD-BALANCE Parent
// GUARD-BALANCE Child
// GUARD-JS

class Child {
	name: string;
	parent: Parent | null = null;
	constructor(name: string) { this.name = name; }
}

class Parent {
	name: string;
	child: Child | null = null;
	constructor(name: string) { this.name = name; }
}

function makePair(i: int32): int32 {
	const p = new Parent("p");
	const c = new Child("c");
	p.child = c;
	c.parent = p;
	return i;
}

function main(): void {
	let total = 0 as int64;
	for (let i = 0 as int32; i < 100000; i += 1) total += makePair(i) as int64;
	console.log(`parent-child-pairs ${total}`);
	console.log("GUARD-OK");
}
main();
