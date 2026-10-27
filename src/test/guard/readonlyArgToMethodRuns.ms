// A view passed to a Readonly parameter of a method call is not held by the receiver
//
// INVARIANT (ULTRALOCK views): a Readonly parameter cannot be kept by its callee, so the call does not
//   make the receiver a holder of the argument, in the method spelling `c.arm(db)` as in the free
//   spelling `arm(c, db)`, for a class and a struct receiver. A callee that stores the view is still
//   refused through its body (readonlyArgToMethodRejects.ms).
//
// RED MEANS: the receiver-holds-arguments flow ignores the callee's parameter types again.
//
// GUARD-JS

struct Db { name: Vec<uint8>; }
struct Slot { key: Vec<uint8>; prefix: Vec<uint8>; }

class Conn {
	key: Vec<uint8> = [1, 2];
	prefix: Vec<uint8> = [];
}

function arm(this c: Conn, db: Readonly<Db>): void { }
function armSlot(this s: Slot, db: Readonly<Db>): void { }

function subscribe(this c: Conn, db: Readonly<Db>): void {
	let outcome = c.key;
	outcome.push(3);
	c.prefix = outcome;
	c.arm(db);
}

function subscribeSlot(this s: Slot, db: Readonly<Db>): int32 {
	let outcome = s.key;
	outcome.push(3);
	s.armSlot(db);
	return outcome.length as int32;
}

function run(db: Readonly<Db>): int32 {
	const c = new Conn();
	c.subscribe(db);
	const s: Slot = { key: [1, 2], prefix: [] };
	return c.prefix.length as int32 + s.subscribeSlot(db);
}

function worker(f: Sendable<() => int32>): int32 { return f(); }

function main(): void {
	const db: Db = { name: [9] };
	const f: Sendable<() => int32> = (): int32 => run(db);
	const n = worker(f);
	if (n != 6) throw new Error(`n=${n}`);
	console.log("GUARD-OK");
}

main();
