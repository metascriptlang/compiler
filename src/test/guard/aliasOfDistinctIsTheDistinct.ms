// guard: an alias of a distinct type is that distinct, so its values share the distinct's hooks
//
// INVARIANT (reference liftdestructors.nim:1284-1286: tyAlias is skipped to the type it names,
//   whose tyDistinct arm :1266-1269 runs the user hook): `type A = D` names D, so a value of A is
//   assignable to D and back, and the program lifts one set of D's hooks.
//
// WHAT IT CATCHES: the alias resolved as a second distinct of the same name ("Type 'Handle' is not
//   assignable to type 'Handle'", a C redefinition of Handle's Destroy when a `Handle | null`
//   field sits beside an alias field), an alias-typed slot that skips its count (double destroy).
//
// AXES: alias-typed constructor argument, class field, local; beside a nullable field of the
//   distinct; assigned both ways.
//
// RED MEANS: the alias of a distinct lost its identity. Run /trace-ref on resolvePass.ms's alias
//   resolution and classify.ms's Alias arm.
// GUARD-BALANCE Node
// GUARD-BALANCE Pair

class Node { id: int32 = 0; }
type Handle = distinct Node;
type HandleAlias = Handle;
function onDestroy(this x: Handle): void { closes += (x as Node).id; }

class Pair { h: Handle | null = null; a: HandleAlias; constructor(a: HandleAlias) { this.a = a; } }

let closes: int32 = 0;

function node(id: int32): Node {
	const n = new Node();
	n.id = id;
	return n;
}

function id(h: Handle): int32 {
	return (h as Node).id;
}

function churn(): void {
	const p = new Pair(node(1) as HandleAlias);
	p.h = node(2) as Handle;
	const k: HandleAlias = node(4) as Handle;
	const j: Handle = node(8) as HandleAlias;
	if (id(k) + id(j) != 12) throw new Error("an alias value lost its node");
}

for (let i: int32 = 0; i < 20; i += 1) churn();
if (closes != 20 * 15) throw new Error(`alias of a distinct ran closes=${closes}, want ${20 * 15}`);
console.log("GUARD-OK");
