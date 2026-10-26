// nim-guard: a Cursor<T> result that enters an owning slot is copied
//
// INVARIANT (injectdestructors.nim p() sinkArg arm: a cursor source is never
//   moved, `not (n.kind == nkSym and isCursor(n))`, so it reaches passCopyToSink):
//   a call whose result is Cursor<T> produces a borrow, and an owning binding,
//   field, element or return that takes it takes its own reference (NIM-REF AN-9).
//
// WHAT IT CATCHES: processCall treating every call result as owned, so an owning
//   slot that takes a cursor result releases a reference nobody gave it
//   (DOUBLE-DESTROY of CoNode) once the cursor routine stops increfing its return.
//
// RED MEANS: the cursor result drifted from Nim. Run /trace-nim on processCall and
//   passCopyToSink in inject.ms.
// GUARD-BALANCE CoNode
// GUARD-BALANCE CoClosurePayload
// GUARD-JS

class CoNode {
	v: int32 = 0;
	next: Cursor<CoNode> = null as unknown as Cursor<CoNode>;
	peer(): Cursor<CoNode> { return this.next; }
}

class CoHolder { kept: CoNode | null = null; }

const linkOf = (n: CoNode): Cursor<CoNode> => n.next;

function owned(n: CoNode): CoNode { return n.peer(); }

function either(n: CoNode, first: boolean): CoNode { return first ? n.peer() : linkOf(n); }

function run(): int32 {
	const owner: CoNode[] = [];
	const a = new CoNode();
	a.v = 1;
	owner.push(a);
	const b = new CoNode();
	b.v = 2;
	b.next = a;
	owner.push(b);
	const held = new CoHolder();
	const kept: CoNode[] = [];
	let sum = 0;
	for (let i = 0; i < 50; i++) {
		const bound: CoNode = b.peer();
		held.kept = linkOf(b);
		kept.push(owned(b));
		const pair: CoNode[] = [b.peer(), linkOf(b)];
		sum += bound.v + held.kept!.v + either(b, i % 2 == 0).v + pair.length;
	}
	sum += kept.length;
	held.kept = null;
	kept.length = 0;
	owner.length = 0;
	return sum;
}

let closurePayloadDestroyed: int32 = 0;

class CoClosurePayload {
	value: int32 = 17;
	onDestroy(): void { closurePayloadDestroyed += 1; }
}

interface CoClosureLink { callback: Cursor<() => int32>; }

function ownedCallback(link: CoClosureLink): () => int32 { return link.callback; }

function closureFromCursorReturn(): () => int32 {
	const payload = new CoClosurePayload();
	const owner = (): int32 => payload.value;
	const link: CoClosureLink = { callback: owner };
	const kept = ownedCallback(link);
	if (owner() != 17) process.exit(1);
	return kept;
}

function closureFromCursorArray(): (() => int32)[] {
	const payload = new CoClosurePayload();
	const owner = (): int32 => payload.value;
	const link: CoClosureLink = { callback: owner };
	const kept: (() => int32)[] = [link.callback];
	if (owner() != 17) process.exit(1);
	return kept;
}

function checkCursorClosureReturn(): void {
	const kept = closureFromCursorReturn();
	when (c) { if (closurePayloadDestroyed != 0) process.exit(1); }
	if (kept() != 17) process.exit(1);
}

function checkCursorClosureArray(): void {
	const kept = closureFromCursorArray();
	when (c) { if (closurePayloadDestroyed != 1) process.exit(1); }
	if (kept[0]() != 17) process.exit(1);
}

checkCursorClosureReturn();
when (c) { if (closurePayloadDestroyed != 1) process.exit(1); }
checkCursorClosureArray();
when (c) { if (closurePayloadDestroyed != 2) process.exit(1); }

if (run() == 50 * 5 + 50) {
	console.log("GUARD-OK");
} else {
	process.exit(1);
}
