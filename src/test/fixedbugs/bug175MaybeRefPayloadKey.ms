// bug175 — the Maybe carrier of a function payload fused every struct pointee
// Symptom: `pick<Box>` then `pick<Pt>` with a `((a: T, b: T) => boolean) | null` formal failed the second
//          instantiation's body check with `got Pt, expected Box`; primitives and a bare `T | null` were fine.
// Root cause: the structural key of a Ref type dropped its pointee, so `Maybe<fn(Ref<Box>, Ref<Box>)>` and
//             `Maybe<fn(Ref<Pt>, Ref<Pt>)>` shared one carrier.
// Fix: the key spells a pointer type by its wrapper and pointee, the way every other composite kind already did.

interface Box175 { w: number; }
interface Pt175 { x: number; }

function pick175<T>(fn: () => T, equals: ((a: T, b: T) => boolean) | null = null): T {
	const v = fn();
	if (equals !== null && equals(v, v)) { return v; }
	return v;
}

function firstSame175<T>(items: T[], same: ((a: T, b: T) => boolean) | null): T {
	if (same !== null) {
		for (let i = 1; i < items.length; i += 1) {
			if (same(items[0], items[i])) { return items[i]; }
		}
	}
	return items[0];
}

test "bug175: a second struct instantiation of a nullable function formal checks and runs" {
	const b = pick175((): Box175 => { const o: Box175 = { w: 1 }; return o; });
	const p = pick175((): Pt175 => { const o: Pt175 = { x: 2 }; return o; });
	assert b.w === 1;
	assert p.x === 2;
}

test "bug175: the comparator runs on each pointee type" {
	let calls = 0;
	const b = pick175((): Box175 => { const o: Box175 = { w: 3 }; return o; }, (a: Box175, c: Box175): boolean => { calls = calls + 1; return a.w === c.w; });
	const p = pick175((): Pt175 => { const o: Pt175 = { x: 4 }; return o; }, (a: Pt175, c: Pt175): boolean => { calls = calls + 1; return a.x === c.x; });
	assert calls === 2;
	assert b.w === 3;
	assert p.x === 4;
}

test "bug175: a nullable comparator over arrays of two pointee types" {
	const boxes: Box175[] = [{ w: 5 }, { w: 6 }, { w: 5 }];
	const pts: Pt175[] = [{ x: 7 }, { x: 7 }];
	const b = firstSame175(boxes, (a: Box175, c: Box175): boolean => a.w === c.w);
	const p = firstSame175(pts, (a: Pt175, c: Pt175): boolean => a.x === c.x);
	const none = firstSame175(pts, null);
	assert b.w === 5;
	assert p.x === 7;
	assert none.x === 7;
}
