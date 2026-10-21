// @stdout: mutable=8 view=8 kid=8 empty=-1
// note: an overload pair hands a mutable argument the mutable projection and a Readonly<T> argument the view, so one helper serves the owner's write and a spawned reader's borrow.

class Node { kids: Node[] = []; n: int32 = 0; }

function first(t: Node): Node | null;
function first(t: Readonly<Node>): Readonly<Node> | null;
function first(t: Readonly<Node>): Readonly<Node> | null {
	if (t.kids.length == 0) return null;
	return t.kids[0];
}

function readFirst(t: Readonly<Node>): int32 {
	const f = first(t);
	return f == null ? -1 : f.n;
}

const root = new Node();
const kid = new Node();
kid.n = 7;
root.kids.push(kid);
const m = first(root);
if (m != null) m.n = 8;
const reader = spawn(() => readFirst(root));
const viewed = await reader;
const leaf = new Node();
console.log(`mutable=${m == null ? -1 : m.n} view=${viewed} kid=${kid.n} empty=${readFirst(leaf)}`);
