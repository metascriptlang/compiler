enum WitnessColor { Red, Green, Blue }

function relayWitness<T>(value: T | null): T | null { return value; }

interface NullableFieldTy { kind: number; }

struct NullableFieldEntry { a: number; t: NullableFieldTy | null; }

interface NullableArrowOps {
	g: (x: int32) => int32 | null;
}

interface NullableArrowStrOps {
	s: (x: string) => string | null;
}

type NullableArrowNullFn = (x: int32) => int32 | null;

interface NullableArrowHolder {
	h: () => () => int32;
}

function nullableArrowInner(): int32 {
	return 7;
}

function nullableArrowUse(cb: (x: int32) => int32 | null): int32 | null {
	return cb(3);
}

enum AliasedConditionKind { Number, Uint64, Int64 }

class AliasedConditionTy { kind: AliasedConditionKind; }

function aliasedConditionAndFalse(ty: AliasedConditionTy | null): string {
	const b = ty != null && ty.kind == AliasedConditionKind.Number;
	if (b) return "num";
	if (ty != null && ty.kind == AliasedConditionKind.Uint64) return "u64";
	return "plain";
}

function aliasedConditionUnrelatedRight(ty: AliasedConditionTy | null, flag: boolean): string {
	const b = ty != null && flag;
	if (b) return "flagged";
	if (ty != null && ty.kind == AliasedConditionKind.Uint64) return "u64";
	return "plain";
}

function aliasedConditionOrTrue(x: AliasedConditionTy | null): string {
	const b = x == null || x.kind == AliasedConditionKind.Number;
	if (b) {
		if (x != null && x.kind == AliasedConditionKind.Number) return "num";
		return "isnull";
	}
	return "other";
}

interface NullableComparatorBox { w: number; }

interface NullableComparatorPt { x: number; }

function nullableComparatorPick<T>(fn: () => T, equals: ((a: T, b: T) => boolean) | null = null): T {
	const v = fn();
	if (equals !== null && equals(v, v)) { return v; }
	return v;
}

function nullableComparatorFirstSame<T>(items: T[], same: ((a: T, b: T) => boolean) | null): T {
	if (same !== null) {
		for (let i = 1; i < items.length; i += 1) {
			if (same(items[0], items[i])) { return items[i]; }
		}
	}
	return items[0];
}

function narrowCastTakesNarrow(v: string | null): string { return v === null ? "N" : "V"; }

function narrowCastTakesNum(v: number | null): string { return v === null ? "N" : "V"; }

function narrowCastTakesBare(v: string): string { return v; }

function narrowCastTakesWide(v: number | string | null): string { return v === null ? "N" : "V"; }

test "nullableInstantiation: nullable inference and explicit substitution preserve absent and present values" {
	const absent: WitnessColor | null = null;
	const present: WitnessColor | null = WitnessColor.Green;
	assert relayWitness<WitnessColor>(absent) == null;
	assert relayWitness(absent) == null;
	assert relayWitness<WitnessColor>(null as WitnessColor | null) == null;
	assert relayWitness(null as WitnessColor | null) == null;
	assert relayWitness<WitnessColor>(present) == WitnessColor.Green;
	assert relayWitness(present) == WitnessColor.Green;
	const text: string | null = "value";
	assert relayWitness(text) == "value";
	assert relayWitness<string>(null) == null;
}

test "nullableInstantiation: nullable-ref struct field survives HashMap round-trip" {
	const m = new HashMap<string, NullableFieldEntry>();
	const ty: NullableFieldTy = { kind: 6 };
	m.set("k", { a: 1, t: ty });
	const g = m.get("k");
	assert g != null;
	if (g != null) {
		assert g.t != null;
		if (g.t != null) assert g.t.kind == 6;
	}
}

test "nullableInstantiation: nullable-ref struct field survives array round-trip" {
	const ty: NullableFieldTy = { kind: 7 };
	const arr: NullableFieldEntry[] = [{ a: 2, t: ty }];
	const g = arr[0];
	assert g.t != null;
	if (g.t != null) assert g.t.kind == 7;
}

test "nullableInstantiation: expr-body arrow into a nullable-returning fn field wraps the Maybe" {
	const o: NullableArrowOps = { g: (x: int32) => x };
	const r = o.g(5);
	assert r != null;
	assert r! == 5;
}

test "nullableInstantiation: annotated expr-body arrow wraps the Maybe" {
	const o: NullableArrowOps = { g: (x: int32): int32 | null => x };
	const r = o.g(6);
	assert r != null;
	assert r! == 6;
}

test "nullableInstantiation: typed-const expr-body arrow wraps the Maybe" {
	const f: NullableArrowNullFn = (x: int32) => x;
	const r = f(4);
	assert r != null;
	assert r! == 4;
}

test "nullableInstantiation: expr-body null literal retypes to the Maybe carrier" {
	const o: NullableArrowOps = { g: (x: int32) => null };
	assert o.g(1) == null;
}

test "nullableInstantiation: string payload expr-body arrow wraps the Maybe" {
	const o: NullableArrowStrOps = { s: (x: string) => x };
	const r = o.s("hi");
	assert r != null;
	assert r! == "hi";
}

test "nullableInstantiation: named function expr-body auto-wraps into a closure" {
	const o: NullableArrowHolder = { h: () => nullableArrowInner };
	const f = o.h();
	assert f() == 7;
}

test "nullableInstantiation: ternary expr-body arrow wraps the Maybe" {
	const o: NullableArrowOps = { g: (x: int32) => (x > 2 ? x : null) };
	assert o.g(5) != null;
	assert o.g(1) == null;
}

test "nullableInstantiation: call-arg expr-body arrow wraps the Maybe" {
	const r = nullableArrowUse((x: int32) => x);
	assert r != null;
	assert r! == 3;
}

test "nullableInstantiation: block-body arrow neighbour stays green" {
	const o: NullableArrowOps = { g: (x: int32) => { return x; } };
	const r = o.g(2);
	assert r != null;
	assert r! == 2;
}

test "nullableInstantiation: fall-through of an aliased && exit keeps the union wide" {
	const tu: AliasedConditionTy = { kind: AliasedConditionKind.Uint64 };
	assert aliasedConditionAndFalse(tu) == "u64";
}

test "nullableInstantiation: unrelated right conjunct does not collapse the reference" {
	const tu: AliasedConditionTy = { kind: AliasedConditionKind.Uint64 };
	assert aliasedConditionUnrelatedRight(tu, false) == "u64";
}

test "nullableInstantiation: aliased || in the true branch keeps both arms" {
	const tn: AliasedConditionTy = { kind: AliasedConditionKind.Number };
	assert aliasedConditionOrTrue(tn) == "num";
}

test "nullableInstantiation: a second struct instantiation of a nullable function formal checks and runs" {
	const b = nullableComparatorPick((): NullableComparatorBox => { const o: NullableComparatorBox = { w: 1 }; return o; });
	const p = nullableComparatorPick((): NullableComparatorPt => { const o: NullableComparatorPt = { x: 2 }; return o; });
	assert b.w === 1;
	assert p.x === 2;
}

test "nullableInstantiation: the comparator runs on each pointee type" {
	let calls = 0;
	const b = nullableComparatorPick((): NullableComparatorBox => { const o: NullableComparatorBox = { w: 3 }; return o; }, (a: NullableComparatorBox, c: NullableComparatorBox): boolean => { calls = calls + 1; return a.w === c.w; });
	const p = nullableComparatorPick((): NullableComparatorPt => { const o: NullableComparatorPt = { x: 4 }; return o; }, (a: NullableComparatorPt, c: NullableComparatorPt): boolean => { calls = calls + 1; return a.x === c.x; });
	assert calls === 2;
	assert b.w === 3;
	assert p.x === 4;
}

test "nullableInstantiation: a nullable comparator over arrays of two pointee types" {
	const boxes: NullableComparatorBox[] = [{ w: 5 }, { w: 6 }, { w: 5 }];
	const pts: NullableComparatorPt[] = [{ x: 7 }, { x: 7 }];
	const b = nullableComparatorFirstSame(boxes, (a: NullableComparatorBox, c: NullableComparatorBox): boolean => a.w === c.w);
	const p = nullableComparatorFirstSame(pts, (a: NullableComparatorPt, c: NullableComparatorPt): boolean => a.x === c.x);
	const none = nullableComparatorFirstSame(pts, null);
	assert b.w === 5;
	assert p.x === 7;
	assert none.x === 7;
}

test "nullableInstantiation: dropping a member type keeps the carrier readable" {
	const a: number | string | null = "row";
	const got = narrowCastTakesNarrow(a as string | null);
	assert got == "V";
}

test "nullableInstantiation: the narrowed carrier reads its payload, not the tag bytes" {
	const a: number | string | null = "row";
	const n: string | null = a as string | null;
	assert n !== null;
	assert n == "row";
}

test "nullableInstantiation: an absent carrier narrows to absent" {
	const a: number | string | null = null;
	const n: string | null = a as string | null;
	assert n === null;
	assert narrowCastTakesNarrow(n) == "N";
}

test "nullableInstantiation: the number member narrows through the same conversion" {
	const a: number | string | null = 42;
	const n: number | null = a as number | null;
	assert n !== null;
	assert n == 42;
	assert narrowCastTakesNum(a as number | null) == "V";
}

test "nullableInstantiation: dropping only null still works" {
	const b: string | null = "row";
	assert narrowCastTakesBare(b as string) == "row";
}

test "nullableInstantiation: the wide union is unchanged without a cast" {
	const a: number | string | null = "row";
	assert narrowCastTakesWide(a) == "V";
}
