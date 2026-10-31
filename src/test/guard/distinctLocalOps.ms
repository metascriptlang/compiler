// guard: a local, parameter or return value of a distinct type takes the distinct's own ops, or
//   its element's when it declares none, nullable or not
//
// INVARIANT (reference liftdestructors.nim:1266-1269 tyDistinct arm with considerUserDefinedOp
//   :502-573; a tyPtr element gets no count): a distinct of a pointer without hooks is never
//   counted, a distinct with onDestroy runs it once per value it holds, and `T | null` runs it
//   only while it holds one.
//
// WHAT IT CATCHES: a `Raw | null` or `Fd | null` local decremented as if it held a counted cell
//   (panic in msHeader), a hooked nullable local that never runs its hook, or a hook called on
//   null.
//
// AXES: distinct of a pointer vs of a class; hooked vs unhooked; nullable vs non-null; a local, a
//   parameter and a return value; held vs null.
//
// RED MEANS: the analyzer classifies a nullable distinct as the counted ref it is not. Run
//   /trace-ref on classify.ms's Union arm.
// GUARD-BALANCE Node

type Raw = distinct Ptr<void>;
type Fd = distinct Ptr<void>;
function onDestroy(this x: Fd): void { fds += 1; }

class Node { id: int32 = 0; }
type Handle = distinct Node;
function onDestroy(this x: Handle): void { handles += (x as Node).id; }

let fds: int32 = 0;
let handles: int32 = 0;
let raws: int32 = 0;

function raw(n: int32): Raw | null {
	if (n == 0) return null;
	return ((n as uint64) as Ptr<void>) as Raw;
}

function fd(n: int32): Fd | null {
	if (n == 0) return null;
	const p = (n as uint64) as Ptr<void>;
	return p as Fd;
}

function openFd(n: int32): Fd {
	const p = (n as uint64) as Ptr<void>;
	return p as Fd;
}

function handle(n: int32): Handle | null {
	if (n == 0) return null;
	const node = new Node();
	node.id = n;
	return node as Handle;
}

function seeRaw(r: Raw | null): void { if (r != null) raws += 1; }
function seeFd(f: Fd | null): boolean { return f != null; }
function seeHandle(h: Handle | null): boolean { return h != null; }

function churn(): void {
	for (let i: int32 = 0; i < 4; i += 1) {
		const r = raw(i);
		seeRaw(r);
		seeRaw(raw(i));
		const f = fd(i);
		if (seeFd(f) != (i != 0)) throw new Error("a nullable Fd lost its value");
		const g = openFd(i + 1);
		const h = handle(i);
		if (seeHandle(h) != (i != 0)) throw new Error("a nullable Handle lost its value");
		seeHandle(handle(i * 10));
	}
}

churn();
console.log("fds", fds, "handles", handles, "raws", raws);
if (fds != 3 + 4 || handles != 6 + 60 || raws != 6) {
	throw new Error(`distinct locals ran fds=${fds} handles=${handles} raws=${raws}`);
}
console.log("GUARD-OK");
