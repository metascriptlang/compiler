// nim-guard: under ORC a cycle that runs through an `unknown` field is collected.
//
// The reference's managed top is RootRef, a non-final ref: cyclicType answers true
// for it (types.nim canFormAcycle, non-final object), its field hooks decref and
// trace through the header type (liftdestructors.nim atomicRefOp: useStatic =
// isFinal(elemType) is false, nimDecRefIsLastCyclicDyn / nimTraceRefDyn).
// Proven red on a5dc802f, where `unknown` was RC-inert: Parent alloc=200 destroy=0,
// Child alloc=200 destroy=0 under orc.
//
// RED MEANS an `unknown` field lost its cyclic hooks or its trace; run /trace-nim
// on the named type.
//
// GUARD-BALANCE-ORC Parent
// GUARD-BALANCE-ORC Child

class Parent {
	child: unknown | null = null;
	name: string = "p";
}

class Child {
	back: unknown | null = null;
	name: string = "c";
}

function link(): int32 {
	const p = new Parent();
	const c = new Child();
	p.child = c;
	c.back = p;
	return (p.name.length + c.name.length) as int32;
}

function main(): void {
	let total = 0 as int32;
	for (let i = 0; i < 200; i += 1) total += link();
	console.log(`unknown-field-cycle ${total}`);
}
main();
