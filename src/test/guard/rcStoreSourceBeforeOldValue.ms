// nim-guard: an RC store evaluates its source before it reads the destination's old value
//
// INVARIANT (injectdestructors.nim:1240-1241 moveOrCopy → genSink(dest, p(ri)) → `=sink(dest, ri)`,
//   :298-300; liftdestructors.nim:873-880 atomicRefOp attachedSink reads `x` inside the hook,
//   after `ri` was evaluated as its argument; NIM-REF AN-32): `h.b = f(h)` where `f` replaces
//   `h.b` releases only the value `h.b` holds when the store happens.
//
// WHAT IT CATCHES: save-assign-destroy saving the old value before the source runs, so the
//   value the source already released is released again (DOUBLE-DESTROY of SbBox or SbTaker) — for a
//   field, an element, a module global, a captured local and a constructor that writes the
//   destination.
//
// RED MEANS: an RC store reads its destination before its source. Run /trace-nim on genSink
//   and genCopy in inject.ms.
// GUARD-BALANCE SbBox
// GUARD-BALANCE SbHolder
// GUARD-BALANCE SbTaker
// GUARD-JS

class SbBox {
	v: int32 = 0;
	constructor(v: int32) { this.v = v; }
}
class SbHolder {
	b: SbBox = new SbBox(0);
	t: SbTaker | null = null;
}
class SbTaker {
	v: int32 = 0;
	constructor(h: SbHolder, v: int32) {
		this.v = v;
		h.t = null;
	}
}

function swapField(h: SbHolder, v: int32): SbBox {
	h.b = new SbBox(v);
	return h.b;
}
function swapElement(a: SbBox[], v: int32): SbBox {
	a[0] = new SbBox(v);
	return a[0];
}
let shared: SbBox = new SbBox(0);
function swapGlobal(v: int32): SbBox {
	shared = new SbBox(v);
	return shared;
}

function run(): string {
	const h = new SbHolder();
	const a: SbBox[] = [new SbBox(0)];
	let x: SbBox = new SbBox(0);
	const swapX = (v: int32): SbBox => {
		x = new SbBox(v);
		return x;
	};
	for (let i = 1; i < 20; i += 1) {
		h.b = swapField(h, i);
		a[0] = swapElement(a, i);
		shared = swapGlobal(i);
		x = swapX(i);
		h.t = new SbTaker(h, i);
	}
	return `${h.b.v},${a[0].v},${shared.v},${x.v},${h.t != null ? h.t.v : -1}`;
}

if (run() == "19,19,19,19,19") {
	console.log("GUARD-OK");
} else {
	process.exit(1);
}
