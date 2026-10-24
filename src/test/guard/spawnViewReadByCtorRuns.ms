// nim-guard: a constructor that only reads a view a task passes it stays accepted.
//
// INVARIANT (ULTRALOCK V5): a view passes freely between functions inside the task, and a
//   scalar read out of it is a COPY. A constructor that reads the view's fields without
//   storing the view takes no count on it, so the task compiles and runs, for a part of a deep
//   Readonly module const and a part of the parent's BORROW, through an own and an inherited
//   constructor.
//
// WHAT IT CATCHES: the constructor-store refusal (spawnViewIntoCtorRejects) firing on every
//   borrowed constructor argument instead of only on one the body stores.
//
// RED MEANS: the build failed, or a task returned a wrong sum.

class Child { n: int32 = 1; }
class Cell { child: Child = new Child(); }
class Sum { n: int32; constructor(c: Readonly<Child>) { this.n = c.n + 1; } }
class Inherited extends Sum {}

const K: Readonly<Cell> = new Cell();

function fromConst(): int32 { return new Sum(K.child).n; }
function fromBorrow(k: Readonly<Cell>): int32 { return new Sum(k.child).n + new Inherited(k.child).n; }

async function main(): Promise<void> {
	const k = new Cell();
	const a = spawn(() => fromConst());
	const b = spawn(() => fromBorrow(k));
	const x = await a;
	const y = await b;
	if (x != 2) throw "GUARD RED: fromConst";
	if (y != 4) throw "GUARD RED: fromBorrow";
	console.log("GUARD-OK");
}

await main();
