// A callee that keeps its Readonly argument is still refused through its body
//
// INVARIANT (ULTRALOCK views): skipping a Readonly parameter in the receiver-holds-arguments flow
//   leaves the callee's own body as the judge: a method that stores the view into the receiver, or
//   a container method that takes it into a sink, makes the Sendable function refuse.
//
// RED MEANS: a Readonly argument stored by its callee passes the crossing check.
//
// GUARD-CHECK-FAIL stores the view 'db' into a sink parameter

struct Db { name: Vec<uint8>; }
class Conn { held: Vec<Readonly<Db>> = []; }
function arm(this c: Conn, db: Readonly<Db>): void { c.held.push(db); }

function run(db: Readonly<Db>): int32 {
	const c = new Conn();
	c.arm(db);
	return c.held.length as int32;
}

function worker(f: Sendable<() => int32>): int32 { return f(); }

function main(): void {
	const db: Db = { name: [9] };
	const f: Sendable<() => int32> = (): int32 => run(db); // GUARD-REFUSED
	console.log(`${worker(f)}`);
}

main();
