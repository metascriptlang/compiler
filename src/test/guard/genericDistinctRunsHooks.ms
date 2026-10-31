// guard: a generic distinct runs its onDestroy once per held value, and no distinct runs it on a zeroed slot
//
// INVARIANT (reference liftdestructors.nim:1266-1269 tyDistinct arm with considerUserDefinedOp
//   :502-573, reached through tyGenericInst at :1284-1286): every path that reaches a
//   distinct asks for its own hook before it descends into the body; a slot that holds no value
//   (zeroed, moved from, null) runs no hook.
//
// WHAT IT CATCHES: a generic distinct instance peeled to its body so its onDestroy never runs
//   (counts 0), a generic hook never bound to the instance, a hook called on a zeroed slot
//   (panic), or a double destroy.
//
// AXES: generic vs plain distinct; local, class field, struct field; non-null vs nullable; held,
//   null, overwritten, moved into a field and into a call.
//
// RED MEANS: a lifting arm or the analyzer's classification skips the distinct's hook. Run
//   /trace-ref on destructorLifting.ms distinctOp, classify.ms classifyDistinct and the hook's
//   binding (context.ms declaredTypeSym).
// GUARD-BALANCE Node
// GUARD-BALANCE Owner
// GUARD-BALANCE Holder

class Node { id: int32 = 0; }
type GHandle<T> = distinct Node;
function onDestroy<T>(this x: GHandle<T>): void { closes += (x as Node).id; }
type Plain = distinct Node;
function onDestroy(this x: Plain): void { closes += (x as Node).id; }

class Owner { g: GHandle<int32> | null = null; p: GHandle<int32>; constructor(p: GHandle<int32>) { this.p = p; } }
struct Slot { g: GHandle<int32>; n: GHandle<int32> | null; }
class Holder { p: Plain; constructor(p: Plain) { this.p = p; } }

let closes: int32 = 0;

function node(id: int32): Node {
	const n = new Node();
	n.id = id;
	return n;
}

function gh(id: int32): GHandle<int32> {
	return node(id) as GHandle<int32>;
}

function count(s: Slot): int32 {
	return s.n == null ? 0 : 1;
}

function expect(want: int32, what: string): void {
	if (closes != want) throw new Error(`${what}: closes=${closes}, want ${want}`);
	closes = 0;
}

function churn(): void {
	{ const a = gh(1); }
	expect(1, "local");
	{ const o = new Owner(gh(2)); o.g = gh(4); }
	expect(6, "class fields");
	{ const o = new Owner(gh(8)); o.g = gh(16); o.g = gh(32); o.g = null; }
	expect(56, "nullable class field overwritten and nulled");
	{ let s: Slot = { g: gh(64), n: gh(128) }; s = { g: gh(256), n: null }; }
	expect(448, "struct overwritten");
	{ const s: Slot = { g: gh(512), n: null }; count(s); }
	expect(512, "struct moved into a call");
	{ const h = gh(1024); const o = new Owner(h); }
	expect(1024, "moved into a field");
	{ const o = new Holder(node(2048) as Plain); o.p = node(4096) as Plain; }
	expect(6144, "plain distinct field set while zeroed, then overwritten");
}

for (let i: int32 = 0; i < 20; i += 1) churn();
console.log("GUARD-OK");
