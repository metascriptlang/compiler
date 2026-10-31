// guard: the hooks of a distinct type run for a nullable field of that type while it holds a value
//
// INVARIANT (reference liftdestructors.nim:1266-1269 tyDistinct arm with considerUserDefinedOp
//   :502-573): a distinct's own destroy hook always runs for its values. `T | null` is a
//   union whose T arm is live when the slot is not null, so it runs exactly once per held value
//   and never for null.
//
// WHAT IT CATCHES: the nullable field taking the plain ref or pointer ops of the wrapped type, so
//   the author's onDestroy never runs for it (counts 0), a hook called on null, an overwritten
//   slot whose old value skips its hook, or a distinct pointer decremented as if it were a
//   counted cell (crash).
//
// AXES: distinct of a class vs distinct of a pointer, hooked vs unhooked; field of a class vs
//   field of a struct; held vs null; destroyed in place vs overwritten by a move.
//
// RED MEANS: a nullable distinct field lost its hooks. Run /trace-ref on fillBody's Union arm
//   (destructorLifting.ms nullableDistinctOp).
// GUARD-BALANCE Node
// GUARD-BALANCE Owner

class Node { id: int32 = 0; }
type Handle = distinct Node;
function onDestroy(this x: Handle): void { closes += (x as Node).id; }

type Fd = distinct Ptr<void>;
function onDestroy(this x: Fd): void { fds += 1; }

type Raw = distinct Ptr<void>;

class Owner { h: Handle | null = null; f: Fd | null = null; r: Raw | null = null; }
struct Slot { h: Handle | null; }

let closes: int32 = 0;
let fds: int32 = 0;

function node(id: int32): Node {
	const n = new Node();
	n.id = id;
	return n;
}

function openFd(n: int32): Fd {
	const p = (n as uint64) as Ptr<void>;
	return p as Fd;
}

function slot(id: int32): Slot {
	return { h: node(id) as Handle };
}

function churn(): void {
	for (let i: int32 = 0; i < 100; i += 1) {
		const held = new Owner();
		held.h = node(1) as Handle;
		held.f = openFd(i + 1);
		held.r = ((i + 1) as uint64) as Ptr<void> as Raw;
		const empty = new Owner();
		let w: Slot = { h: node(10) as Handle };
		if (w.h == null) throw new Error("a slot lost its handle");
		w = slot(20);
		const u: Slot = { h: null };
		if (u.h != null) throw new Error("an empty slot holds a handle");
	}
}

churn();
console.log("closes", closes, "fds", fds);
if (closes != 100 * (1 + 10 + 20) || fds != 100) {
	throw new Error(`nullable distinct hooks ran closes=${closes} fds=${fds}`);
}
console.log("GUARD-OK");
