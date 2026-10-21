// nim-guard: returning into a Cursor<T> result is a plain read
//
// INVARIANT (injectdestructors.nim moveOrCopy: `isCursor(dest)` takes
//   `nkFastAsgn(dest, p(ri, c, s, normal))`, no copy): a routine whose result is
//   Cursor<T> hands back a borrow, so its return takes no reference that a caller
//   would have to release (NIM-REF AN-9: incref only when entering an owning slot).
//
// WHAT IT CATCHES: processReturn walking a Cursor result in Consumed mode, which
//   increfs the returned link (a cursor local, a cursor field, a nested cursor
//   call) while every caller reads it as a cursor and never releases it, so the
//   scope it points at outlives its owner (CrScope alloc=2 destroy=0).
//
// RED MEANS: the cursor result drifted from Nim. Run /trace-nim on processReturn
//   in inject.ms.
// GUARD-BALANCE CrScope
// GUARD-JS

class CrScope {
	depth: int32 = 0;
	parent: Cursor<CrScope> = null as unknown as Cursor<CrScope>;
}

class CrTable { current: Cursor<CrScope> = null as unknown as Cursor<CrScope>; }

function outermost(t: CrTable): Cursor<CrScope> {
	let s = t.current;
	while (s.parent != null) s = s.parent;
	return s;
}

function current(t: CrTable): Cursor<CrScope> { return t.current; }

function enclosing(t: CrTable): Cursor<CrScope> { return current(t).parent; }

function run(): int32 {
	const owner: CrScope[] = [];
	const top = new CrScope();
	owner.push(top);
	const inner = new CrScope();
	inner.depth = 1;
	inner.parent = top;
	owner.push(inner);
	const t = new CrTable();
	t.current = inner;
	let sum = 0;
	for (let i = 0; i < 100; i++) {
		sum += outermost(t).depth + current(t).depth + enclosing(t).depth;
	}
	t.current = null as unknown as Cursor<CrScope>;
	owner.length = 0;
	return sum;
}

if (run() == 100) {
	console.log("GUARD-OK");
} else {
	process.exit(1);
}
