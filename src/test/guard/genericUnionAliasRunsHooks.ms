// guard: a hook declared on a generic union alias instance runs once per held value, as a named
//   union's hook does
//
// INVARIANT (reference semstmts.nim:2357-2369 normalizeTypeHook binds a hook through
//   tyGenericInst to the instance's own type; liftdestructors.nim:1250 asks considerUserDefinedOp
//   :502-573 for that type, which reaches a generic hook through its t.typeInst at :508-511): a hook
//   on `Gen<Leaf>` or on every `Each<T>` binds to the instance, and every path that reaches the
//   instance's union body runs it, whichever path lifts the body first.
//
// WHAT IT CATCHES: the hook never bound (no error, counts 0), a body lifted before its instance so
//   the hook is skipped, one instance's hook run for another, the named union's hook run for the
//   instance, or a double destroy.
//
// AXES: generic instance vs named union; one instance's hook vs a hook of every instance declared
//   after its uses; Gen<Leaf> vs Gen<number>, Each<Leaf> vs Each<Bud>; local, class field,
//   struct field; non-null vs nullable; held, overwritten, nulled, moved into a field and into a call.
//
// RED MEANS: the binding or the hook lookup drops the instance's hook. Run /trace-ref on
//   context.ms declaredTypeSym and instantiate.ms lookupInstanceHook (the body's typeInst).
// GUARD-BALANCE Leaf
// GUARD-BALANCE Twig
// GUARD-BALANCE Bud
// GUARD-BALANCE Owner
// GUARD-BALANCE Nest

class Leaf { id: int32 = 0; }
class Twig { id: int32 = 0; }
class Bud { id: int32 = 0; }
type Plain = Leaf | Twig;
type Gen<T> = T | Twig;
type Each<T> = T | Twig;

let plainCloses: int32 = 0;
let genCloses: int32 = 0;
let numCloses: int32 = 0;
let eachCloses: int32 = 0;
let reads: int32 = 0;

function held(x: Leaf | Twig): int32 {
	if (x instanceof Leaf) return x.id;
	if (x instanceof Twig) return x.id;
	return 0;
}

function onDestroy(this p: Plain): void { plainCloses += held(p); }
function onDestroy(this g: Gen<Leaf>): void { genCloses += held(g); }
function onDestroy(this g: Gen<number>): void { numCloses += typeof g == "number" ? g as int32 : held(g); }

class Owner { g: Gen<Leaf>; n: Gen<Leaf> | null = null; constructor(g: Gen<Leaf>) { this.g = g; } }
class Nest { e: Each<Bud>; constructor(e: Each<Bud>) { this.e = e; } }
struct Slot { g: Gen<Leaf>; k: Gen<number>; }

function leaf(id: int32): Leaf {
	const l = new Leaf();
	l.id = id;
	return l;
}

function twig(id: int32): Twig {
	const t = new Twig();
	t.id = id;
	return t;
}

function num(v: number): Gen<number> {
	return v;
}

function bud(id: int32): Bud {
	const b = new Bud();
	b.id = id;
	return b;
}

function take(g: Gen<Leaf>): int32 {
	return held(g);
}

function expect(plain: int32, gen: int32, num: int32, each: int32, what: string): void {
	if (plainCloses != plain || genCloses != gen || numCloses != num || eachCloses != each) {
		throw new Error(`${what}: plain=${plainCloses} gen=${genCloses} num=${numCloses} each=${eachCloses}, want ${plain} ${gen} ${num} ${each}`);
	}
	plainCloses = 0;
	genCloses = 0;
	numCloses = 0;
	eachCloses = 0;
}

function churn(): void {
	{ const p: Plain = leaf(1); const g: Gen<Leaf> = leaf(2); reads += held(p) + held(g); }
	expect(1, 2, 0, 0, "named union and instance locals");
	{ const g: Gen<Leaf> = twig(4); reads += held(g); }
	expect(0, 4, 0, 0, "instance local holding the shared arm");
	{ const k: Gen<number> = num(8); const t: Gen<number> = twig(16); reads += (typeof k == "number" ? 1 : 0) + (typeof t == "number" ? 0 : 1); }
	expect(0, 0, 24, 0, "second instance");
	{ const o = new Owner(leaf(32)); o.g = twig(64); }
	expect(0, 96, 0, 0, "class field overwritten");
	{ const o = new Owner(leaf(1)); o.n = leaf(128); o.n = twig(256); o.n = null; }
	expect(0, 385, 0, 0, "nullable class field overwritten and nulled");
	{ const n: Gen<Leaf> | null = leaf(512); reads += n != null ? 1 : 0; }
	expect(0, 512, 0, 0, "nullable local");
	{ let s: Slot = { g: leaf(1024), k: 2048 }; s = { g: twig(4096), k: twig(8192) }; reads += typeof s.k == "number" ? 0 : 1; }
	expect(0, 5120, 10240, 0, "struct overwritten");
	{ const g: Gen<Leaf> = leaf(16384); take(g); }
	expect(0, 16384, 0, 0, "moved into a call");
	{ const g: Gen<Leaf> = leaf(32768); const o = new Owner(g); }
	expect(0, 32768, 0, 0, "moved into a field");
	{ const e: Each<Leaf> = leaf(3); const b: Each<Bud> = bud(5); reads += (e != null ? 1 : 0) + (b != null ? 1 : 0); }
	expect(0, 0, 0, 2, "hook of every instance, declared after its uses");
	{ const n = new Nest(bud(7)); n.e = twig(9); }
	expect(0, 0, 0, 2, "hook of every instance on a class field overwritten");
}

function onDestroy<T>(this e: Each<T>): void { eachCloses += 1; }

for (let i: int32 = 0; i < 20; i += 1) churn();
console.log("GUARD-OK");
