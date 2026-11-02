// guard: a local of a union with a user hook runs the hook once at scope end, whether or not
//   the local is read
//
// INVARIANT (reference varpartitions.nim:483-488 destMightOwn: an object constructor of a type with
//   a destructor owns, so computeCursors :1055 never makes its target a cursor; injectdestructors.nim:668
//   destroys every non-cursor local at scope end): wrapping a value into a tag-carried union builds
//   a new union value, so its local owns that value and is destroyed, never borrowed.
//
// WHAT IT CATCHES: the wrap read as a transparent borrow, so a never-read local becomes a cursor and
//   its hook never runs (count 0), or the borrow from a parameter is not counted (double destroy,
//   ledger imbalance).
//
// AXES: named union vs generic alias instance; never read vs read; from a call vs from a parameter.
//
// RED MEANS: cursor inference treats a union-building conversion as a borrow. Run /trace-ref on
//   cursors.ms destMightOwn.
// GUARD-BALANCE Leaf

class Leaf { id: int32 = 0; }
class Twig { id: int32 = 0; }
type Plain = Leaf | Twig;
type Gen<T> = T | Twig;

let plainCloses: int32 = 0;
let genCloses: int32 = 0;

function held(x: Leaf | Twig): int32 {
	if (x instanceof Leaf) return x.id;
	if (x instanceof Twig) return x.id;
	return 0;
}

function onDestroy(this p: Plain): void { plainCloses += held(p); }
function onDestroy(this g: Gen<Leaf>): void { genCloses += held(g); }

function leaf(id: int32): Leaf {
	const l = new Leaf();
	l.id = id;
	return l;
}

function unreadPlain(): void { const p: Plain = leaf(1); }
function readPlain(): void { const p: Plain = leaf(2); if (held(p) != 2) throw new Error("read"); }
function unreadGen(): void { const g: Gen<Leaf> = leaf(4); }
function unreadFromParam(l: Leaf): void { const p: Plain = l; }
function unreadGenFromParam(l: Leaf): void { const g: Gen<Leaf> = l; }

function expect(plain: int32, gen: int32, what: string): void {
	if (plainCloses != plain || genCloses != gen) {
		throw new Error(`${what}: plain=${plainCloses} gen=${genCloses}, want ${plain} ${gen}`);
	}
	plainCloses = 0;
	genCloses = 0;
}

function churn(): void {
	unreadPlain();
	expect(1, 0, "named union, never read");
	readPlain();
	expect(2, 0, "named union, read");
	unreadGen();
	expect(0, 4, "generic alias instance, never read");
	const kept = leaf(8);
	unreadFromParam(kept);
	expect(8, 0, "named union from a parameter, never read");
	unreadGenFromParam(kept);
	expect(0, 8, "generic alias instance from a parameter, never read");
	if (kept.id != 8) throw new Error("the parameter's value was released by the callee");
}

for (let i: int32 = 0; i < 20; i += 1) churn();
console.log("GUARD-OK");
