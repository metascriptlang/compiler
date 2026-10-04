type StoredVariant = { ok: true, val: int32 } | { ok: false, msg: string };

function variantRows(count: int32): StoredVariant[] {
	const rows: StoredVariant[] = [];
	for (let i: int32 = 0; i < count; i++) {
		if (i % 2 == 0) rows.push({ ok: false, msg: "msg_" + i.toString() });
		else rows.push({ ok: true, val: i });
	}
	return rows;
}

interface ProjectionBox { value: int32; payload: string; }

interface ProjectionOuter { inner: ProjectionBox; tag: string; }

function directProjection(): int32 {
	const box: ProjectionBox = { value: 42, payload: "padding to make sure heap allocation" };
	return box.value;
}

function nestedProjection(): int32 {
	const outer: ProjectionOuter = { inner: { value: 7, payload: "x" }, tag: "outer" };
	return outer.inner.value;
}

function arrayProjection(): int32 { const values: int32[] = [10, 20, 30]; return values[1]; }

struct EntryLookupPair<K, V> { hcode: int64; key: K; value: V; }

class EntryLookupMap<K, V> {
	entries: EntryLookupPair<K, V>[];
}

function entryLookupLookup<K, V>(m: EntryLookupMap<K, V>, target: K, h: int64): boolean {
	let i = 0;
	while (i < m.entries.length) {
		const e = m.entries[i];
		if (e.hcode == h && e.key == target) { return true; }
		i = i + 1;
	}
	return false;
}

interface TupleProjectionTy { kind: number; }

interface TupleProjectionHolder { p: [TupleProjectionTy, number]; }

interface SpreadPrecedenceStyle { width: number | null; height: number | null; }

interface SpreadPrecedencePt { x: number; y: number; label: string; }

let spreadPrecedenceCalls = 0;

function spreadPrecedenceMk(): SpreadPrecedencePt {
	spreadPrecedenceCalls = spreadPrecedenceCalls + 1;
	return { x: 1, y: 2, label: "mk" };
}

function spreadPrecedenceDist(p: SpreadPrecedencePt): number {
	return p.x + p.y;
}

interface VariantReplacementA { kind: "a"; label: string; n: int32; }

interface VariantReplacementB { kind: "b"; label: string; f: float64; }

type VariantReplacementU = VariantReplacementA | VariantReplacementB;

function variantReplacementU(which: boolean, n: int32): VariantReplacementU {
	if (which) {
		const a: VariantReplacementA = { kind: "a", label: "L" + n.toString(), n: n };
		return a;
	}
	const b: VariantReplacementB = { kind: "b", label: "M" + n.toString(), f: 1.5 };
	return b;
}

function variantReplacementRead(u: VariantReplacementU): string {
	return u.label;
}

function variantReplacementCross(): string {
	let u: VariantReplacementU = variantReplacementU(true, 1);
	const first = variantReplacementRead(u);
	u = variantReplacementU(false, 2);
	return first + "|" + u.kind + "|" + variantReplacementRead(u);
}

function variantReplacementSame(): string {
	let u: VariantReplacementU = variantReplacementU(true, 1);
	const first = variantReplacementRead(u);
	u = variantReplacementU(true, 8);
	return first + "|" + u.kind + "|" + variantReplacementRead(u);
}

function variantReplacementChurn(): int32 {
	let u: VariantReplacementU = variantReplacementU(true, 0);
	let ok = 0;
	for (let i = 1; i <= 40; i += 1) {
		const before = variantReplacementRead(u);
		u = variantReplacementU(i % 2 == 0, i);
		const want = i % 2 == 0 ? "L" + i.toString() : "M" + i.toString();
		const previous = i - 1;
		const wantBefore = previous % 2 == 0 ? "L" + previous.toString() : "M" + previous.toString();
		if (variantReplacementRead(u) == want && before == wantBefore) {
			ok += 1;
		}
	}
	return ok;
}

interface UpdateOperandCounter { n: int32; }

interface MappedElementP { x: number; tag: string; }

export type Dir = "column" | "column-reverse" | "row" | "row-reverse";

export function dirToC(v: Dir): int32 {
	return match (v) {
		"column" => 0,
		"column-reverse" => 1,
		"row" => 2,
		"row-reverse" => 3,
	};
}

interface Holder {
	dir: Dir;
	label: string;
}

struct SizedSequenceFighter { power: int64; health: int64; }

type SizedSequenceRow = int32[3];

struct SizedSequenceRoster { count: uint8; fighters: SizedSequenceFighter[4]; }

function sizedSequenceRoster(): SizedSequenceRoster {
	return { count: 4, fighters: [{ power: 1, health: 0 }, { power: 2, health: 0 }, { power: 3, health: 0 }, { power: 4, health: 0 }] };
}

function sizedSequenceSumParam(xs: int64[3]): int64 {
	let total: int64 = 0;
	for (let i = 0; i < xs.length; i += 1) { total = total + xs[i]; }
	return total + xs.length;
}

function sizedSequenceSumRef(ref r: SizedSequenceRoster): int64 {
	let total: int64 = 0;
	for (const fighter of r.fighters) { total = total + fighter.power; }
	return total * r.fighters.length;
}

function sizedSequenceViaRef(): int64 {
	let roster = sizedSequenceRoster();
	return sizedSequenceSumRef(roster);
}

struct WritableBindingIn { v: int32; }

struct WritableBindingS { a: int32; inner: WritableBindingIn; xs: int32[3]; }

type WritableBindingO = { a: int32 };

interface WritableBindingI { a: int32; }

class WritableBindingC { a: int32 = 0; }

function writableBindingRebind(p: int32): int32 {
	p = p + 1;
	return p;
}

test "valueStorage: union arrays preserve every active payload across repeated construction and teardown" {
	for (let round: int32 = 0; round < 50; round++) {
		const rows = variantRows(20);
		assert rows.length == 20;
		for (let i: int32 = 0; i < rows.length; i++) {
			const row = rows[i];
			assert row.ok == (i % 2 != 0);
			if (row.ok) assert row.val == i;
			else assert row.msg == "msg_" + i.toString();
		}
	}
}

test "valueStorage: return projection preserves the selected value independently of container shape" {
	assert directProjection() == 42;
	assert nestedProjection() == 7;
	assert arrayProjection() == 20;
}

test "valueStorage: generic struct array lookup preserves key and hash comparisons" {
	const m = new EntryLookupMap<string, number>();
	m.entries = [
		{ hcode: 100 as int64, key: "alice-heap-string", value: 1 },
		{ hcode: 200 as int64, key: "bob-heap-string", value: 2 },
	];
	assert entryLookupLookup(m, "alice-heap-string", 100 as int64);
	assert !entryLookupLookup(m, "carol", 999 as int64);
}

test "valueStorage: tuple element type inferred without annotation (struct field)" {
	const t: TupleProjectionTy = { kind: 6 };
	const h: TupleProjectionHolder = { p: [t, 11] };
	const a = h.p[0];
	const b = h.p[1];
	assert a.kind == 6;
	assert b == 11;
}

test "valueStorage: tuple element type inferred without annotation (bare local)" {
	const t: TupleProjectionTy = { kind: 9 };
	const p: [TupleProjectionTy, number] = [t, 42];
	const a = p[0];
	const b = p[1];
	assert a.kind == 9;
	assert b == 42;
}

test "valueStorage: map subscript reads preserve keys and values in expression consumers" {
	const values = new HashMap<string, int32>();
	const keys: string[] = ["a", "b", "c"];
	for (let i: int32 = 0; i < keys.length; i++) values.set(keys[i], i + 5);
	for (let i: int32 = 0; i < keys.length; i++) assert values[keys[i]] == i + 5;
	assert values["a"]! + values["c"]! == 12;
}

test "valueStorage: spread + explicit override" {
	const base: SpreadPrecedenceStyle = { width: 10.0 };
	const merged: SpreadPrecedenceStyle = { ...base, height: 20.0 };
	assert merged.width == 10.0;
	assert merged.height == 20.0;
	assert base.height == null;
}

test "valueStorage: spread copies every field independently of later source mutation" {
	let p: SpreadPrecedencePt = { x: 3, y: 4, label: "src" };
	const q: SpreadPrecedencePt = { ...p };
	p.x = 8;
	p.y = 9;
	p.label = "second";
	assert q.x == 3;
	assert q.y == 4;
	assert q.label == "src";
	assert p.x == 8;
	assert p.y == 9;
	assert p.label == "second";
}

test "valueStorage: later spread wins field-wise (static-type semantics)" {
	const a: SpreadPrecedenceStyle = { width: 1.0, height: 2.0 };
	const b: SpreadPrecedenceStyle = { height: 9.0 };
	const m: SpreadPrecedenceStyle = { ...a, ...b };
	assert m.width == null;
	assert m.height == 9.0;
}

test "valueStorage: explicit key before spread is overridden" {
	const p: SpreadPrecedencePt = { x: 5, y: 6, label: "base" };
	const m: SpreadPrecedencePt = { label: "pre", ...p };
	assert m.label == "base";
	assert m.x == 5;
}

test "valueStorage: call operand is hoisted and evaluated once" {
	spreadPrecedenceCalls = 0;
	const m: SpreadPrecedencePt = { ...spreadPrecedenceMk(), y: 7 };
	assert spreadPrecedenceCalls == 1;
	assert m.x == 1;
	assert m.y == 7;
	assert m.label == "mk";
}

test "valueStorage: spread literal in argument position" {
	const p: SpreadPrecedencePt = { x: 3, y: 4, label: "p" };
	assert spreadPrecedenceDist({ ...p, y: 10 }) == 13;
}

test "valueStorage: sink carries the payload across variants" {
	assert variantReplacementCross() == "L1|b|M2";
}

test "valueStorage: sink replaces same-variant fields" {
	assert variantReplacementSame() == "L1|a|L8";
}

test "valueStorage: repeated sink assignment stays consistent" {
	assert variantReplacementChurn() == 40;
}

test "valueStorage: prefix update reaches the array element" {
	const a: int32[] = [4, 7];
	const v = ++a[1];
	assert v == 8;
	assert a[1] == 8;
	assert a[0] == 4;
	--a[0];
	assert a[0] == 3;
}

test "valueStorage: prefix update reaches the member" {
	const o: UpdateOperandCounter = { n: 4 };
	const v = ++o.n;
	assert v == 5;
	assert o.n == 5;
	--o.n;
	assert o.n == 4;
}

test "valueStorage: postfix on member and element still yields the old value" {
	const o: UpdateOperandCounter = { n: 4 };
	const a: int32[] = [9];
	assert o.n++ == 4;
	assert a[0]-- == 9;
	assert o.n == 5;
	assert a[0] == 8;
}

test "valueStorage: map over numbers keeps the length and applies the mapper in order" {
	const xs: number[] = [1, 2, 3];
	const ys = xs.map((x: number): number => x * 2);
	assert ys.length === 3, "length " + ys.length.toString();
	assert ys[0] === 2 && ys[1] === 4 && ys[2] === 6, "values " + ys[0].toString() + ys[1].toString() + ys[2].toString();
	assert xs[0] === 1, "source untouched";
}

test "valueStorage: the mapper receives the index and may change the element type" {
	const xs: string[] = ["a", "b"];
	const tagged = xs.map((s: string, i: number): string => s + i.toString());
	assert tagged[0] === "a0" && tagged[1] === "b1", tagged[0] + tagged[1];
	const lens = xs.map((s: string): number => s.length + 1);
	assert lens[0] === 2 && lens[1] === 2, lens[0].toString();
}

test "valueStorage: map over interface structs and into them" {
	const ps: MappedElementP[] = [{ x: 3, tag: "p" }, { x: 4, tag: "q" }];
	const xs = ps.map((p: MappedElementP): number => p.x);
	assert xs[0] === 3 && xs[1] === 4, xs[1].toString();
	const back = xs.map((n: number): MappedElementP => ({ x: n * 10, tag: "m" }));
	assert back[1].x === 40 && back[1].tag === "m", back[1].tag;
}

test "valueStorage: an empty array maps to an empty array" {
	const none: number[] = [];
	const ys = none.map((x: number): number => x);
	assert ys.length === 0;
}

test "valueStorage: a named string-literal union matches on its msString carrier" {
	const d: Dir = "row";
	assert dirToC(d) === 2, "row";
}

test "valueStorage: a struct field typed by a named string-literal union copies and drops as a string" {
	const a: Holder = { dir: "row-reverse", label: "x" };
	const b = a;
	assert dirToC(b.dir) === 3 && b.label === "x", "copy";
}

test "valueStorage: length and for..of of a sized struct field" {
	const roster = sizedSequenceRoster();
	let total: int64 = 0;
	for (const fighter of roster.fighters) { total = total + fighter.power; }
	assert total == 10;
	assert roster.fighters.length == 4;
}

test "valueStorage: length of a local sized array in an expression and as a loop bound" {
	const xs: int32[5] = [1, 2, 3, 4, 5];
	let total: int32 = 0;
	for (let i = 0; i < xs.length; i += 1) { total = total + xs[i]; }
	assert total == 15;
	assert xs.length * 2 - 1 == 9;
}

test "valueStorage: length of a sized array parameter and through a ref struct" {
	const xs: int64[3] = [10, 20, 30];
	assert sizedSequenceSumParam(xs) == 63;
	assert sizedSequenceViaRef() == 40;
}

test "valueStorage: length of a nested sized array" {
	const grid: SizedSequenceRow[2] = [[1, 2, 3], [4, 5, 6]];
	let cells: int32 = 0;
	for (const row of grid) { cells = cells + row.length; }
	assert grid.length == 2;
	assert cells == 6;
	assert grid[1].length == 3;
}

test "valueStorage: a let struct is writable to the last field" {
	let s: WritableBindingS = { a: 1, inner: { v: 1 }, xs: [1, 2, 3] };
	s.a = 2;
	s.inner.v = 5;
	s.xs[1] = 6;
	s.a += 1;
	assert s.a == 3;
	assert s.inner.v == 5;
	assert s.xs[1] == 6;
}

test "valueStorage: a const object type, interface or class fixes the binding, not its fields" {
	const o: WritableBindingO = { a: 1 };
	o.a = 2;
	const i: WritableBindingI = { a: 1 };
	i.a = 3;
	const c = new WritableBindingC();
	c.a = 4;
	assert o.a == 2;
	assert i.a == 3;
	assert c.a == 4;
}

test "valueStorage: a const T[] writes its elements" {
	const xs: int32[] = [1, 2];
	xs[0] = 9;
	assert xs[0] == 9;
}

test "valueStorage: a parameter can be rebound" {
	assert writableBindingRebind(1) == 2;
}

test "valueStorage: a const Ptr<T> writes its pointee" {
	const owner = new WritableBindingC();
	const p: Ptr<WritableBindingC> = owner;
	p.a = 7;
	assert owner.a == 7;
}

enum ByteVectorFlag { Changed, Paint }
enum WordVectorFlag { Changed, Paint, C, D, E, F, G, H, High }
interface ByteSetVectorOwner { bits: Vec<BitSet<ByteVectorFlag>>; }
interface WordSetVectorOwner { bits: Vec<BitSet<WordVectorFlag>>; }

test "valueStorage: replacing a nonempty byte-bitset vector preserves reusable field storage" {
	const owner: ByteSetVectorOwner = { bits: [] };
	const changed = (0 as BitSet<ByteVectorFlag>).incl(ByteVectorFlag.Changed);
	for (let i: int32 = 0; i < 8; i++) { owner.bits.push(changed); }
	assert owner.bits[7].has(ByteVectorFlag.Changed);
	owner.bits = new Array(0);
	assert owner.bits.length == 0;
	owner.bits.push((0 as BitSet<ByteVectorFlag>).incl(ByteVectorFlag.Paint));
	assert owner.bits.length == 1;
	assert owner.bits[0].has(ByteVectorFlag.Paint);
	assert !owner.bits[0].has(ByteVectorFlag.Changed);
}

test "valueStorage: replacing a nonempty word-bitset vector retains high ordinal bits" {
	const owner: WordSetVectorOwner = { bits: [] };
	const changed = (0 as BitSet<WordVectorFlag>).incl(WordVectorFlag.Changed);
	for (let i: int32 = 0; i < 8; i++) { owner.bits.push(changed); }
	assert owner.bits[7].has(WordVectorFlag.Changed);
	owner.bits = new Array(0);
	assert owner.bits.length == 0;
	owner.bits.push((0 as BitSet<WordVectorFlag>).incl(WordVectorFlag.High));
	assert owner.bits.length == 1;
	assert owner.bits[0].has(WordVectorFlag.High);
	assert !owner.bits[0].has(WordVectorFlag.Changed);
}

enum AggregateVectorFlag {
	F0, F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12, F13, F14, F15,
	F16, F17, F18, F19, F20, F21, F22, F23, F24, F25, F26, F27, F28, F29, F30, F31,
	F32, F33, F34, F35, F36, F37, F38, F39, F40, F41, F42, F43, F44, F45, F46, F47,
	F48, F49, F50, F51, F52, F53, F54, F55, F56, F57, F58, F59, F60, F61, F62, F63,
	F64,
}



test "valueStorage: conditional word-bitset storage is typed and lazy" {
	let calls: int32 = 0;
	const makeValue = (): BitSet<WordVectorFlag> => {
		calls += 1;
		return (0 as BitSet<WordVectorFlag>).incl(WordVectorFlag.High);
	};
	const selected = true ? (0 as BitSet<WordVectorFlag>) : makeValue();
	assert selected.isEmpty();
	assert calls == 0;
}

test "valueStorage: conditional aggregate-bitset storage is typed and lazy" {
	let calls: int32 = 0;
	const makeValue = (): BitSet<AggregateVectorFlag> => {
		calls += 1;
		return (0 as BitSet<AggregateVectorFlag>).incl(AggregateVectorFlag.F64);
	};
	const selected = true ? (0 as BitSet<AggregateVectorFlag>) : makeValue();
	assert selected.isEmpty();
	assert calls == 0;
}

test "valueStorage: aggregate-bitset arrow bodies hoist inside their own scope" {
	const makeBase = (): BitSet<AggregateVectorFlag> => (0 as BitSet<AggregateVectorFlag>).incl(AggregateVectorFlag.F0);
	const deferred = (): BitSet<AggregateVectorFlag> => makeBase().incl(AggregateVectorFlag.F64);
	const value = deferred();
	assert value.has(AggregateVectorFlag.F0);
	assert value.has(AggregateVectorFlag.F64);
}

struct WordSetZeroHolder { bits: BitSet<WordVectorFlag>; }
struct AggregateSetZeroHolder { bits: BitSet<AggregateVectorFlag>; }

test "valueStorage: word-bitset locations start at the zero value" {
	let local: BitSet<WordVectorFlag>;
	const holder: WordSetZeroHolder = {};
	const values: Vec<BitSet<WordVectorFlag>> = new Array(3);
	assert local.isEmpty();
	assert holder.bits.isEmpty();
	assert values[0].isEmpty();
	assert values[2].isEmpty();
}

test "valueStorage: aggregate-bitset locations start at independent zero values" {
	let local: BitSet<AggregateVectorFlag>;
	const holder: AggregateSetZeroHolder = {};
	let values: Vec<BitSet<AggregateVectorFlag>> = new Array(3);
	assert local.isEmpty();
	assert holder.bits.isEmpty();
	assert values[0].isEmpty();
	assert values[2].isEmpty();
	values[0] = values[0].incl(AggregateVectorFlag.F64);
	assert values[0].has(AggregateVectorFlag.F64);
	assert values[1].isEmpty();
}
