// @stdout: 0 0 0 0 5 3
// @stdout: caught boom
// @exit: 0

struct P { x: int32; }
struct Q { p: P; }
class K { x: int32 = 1; }

function boom(): never { throw new Error("boom"); }

function structLocal(c: boolean): int32 {
	if (c) { const q: P = boom(); return q.x; }
	return 0;
}

function intLocal(c: boolean): int32 {
	if (c) { const q: int32 = boom(); return q; }
	return 0;
}

function classLocal(c: boolean): int32 {
	if (c) { const q: K = boom(); return q.x; }
	return 0;
}

function tupleLocal(c: boolean): int32 {
	if (c) { const q: [int32, string] = boom(); return q[0]; }
	return 0;
}

function fieldAssign(c: boolean): int32 {
	let q: Q = { p: { x: 5 } };
	if (c) { q.p = boom(); }
	return q.p.x;
}

function returned(c: boolean): P {
	if (c) { return boom(); }
	return { x: 3 };
}

console.log(`${structLocal(false)} ${intLocal(false)} ${classLocal(false)} ${tupleLocal(false)} ${fieldAssign(false)} ${returned(false).x}`);
try {
	structLocal(true);
} catch (e) {
	console.log(`caught ${(e as Error).message}`);
}
