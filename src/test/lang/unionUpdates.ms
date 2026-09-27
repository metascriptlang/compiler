function typeofProjectionApply(v: int32 | ((prev: int32) => int32), cur: int32): int32 {
	if (typeof v === "function") { return v(cur); }
	return v;
}

function applyUpdate<T>(v: T | ((prev: T) => T), cur: T): T {
	if (typeof v === "function") { return v(cur); }
	return v;
}

function typeofProjectionPick(v: string | int32): int32 {
	if (typeof v === "number") { return v + 1; }
	return v.length;
}

function typeofProjectionChain(v: string | int32 | boolean): int32 {
	if (typeof v === "boolean") { return v ? 1 : 0; }
	if (typeof v === "number") { return v * 2; }
	return v.length;
}

interface TypeofProjectionPoint { x: int32; }

function typeofProjectionUnwrap(v: TypeofProjectionPoint | int32): int32 {
	if (typeof v === "object") { return v.x; }
	return v;
}

function typeofProjectionNotFn(v: int32 | (() => int32)): int32 {
	if (typeof v !== "function") { return v + 1; }
	return v();
}

function arrayUnionLen(v: int32[] | int32): int32 {
	if (typeof v === "object") { return v.length; }
	return v;
}

function arrayUnionTotal(xs: int32[]): int32 {
	let sum = 0;
	for (const x of xs) sum += x;
	return sum;
}

type ContextualCellSetter<T> = (v: T | ((prev: T) => T)) => void;

function contextualCellCell<T>(init: T): [() => T, ContextualCellSetter<T>] {
	let cur: T = init;
	return [
		() => cur,
		(v: T | ((prev: T) => T)) => {
			if (typeof v === "function") { cur = v(cur); } else { cur = v; }
		},
	];
}

type AliasCellSetter<T> = (v: T | ((prev: T) => T)) => void;

interface AliasCellCell { setter: AliasCellSetter<number> | null; }

function aliasCellMk(): [() => number, AliasCellSetter<number>] {
	let cur = 0.5;
	return [() => cur, (v) => { if (typeof v === "function") { cur = v(cur); } else { cur = v; } }];
}

type NullableUnionN = string | null;

type NullableUnionSetter<T> = (v: T | ((prev: T) => T)) => void;

function nullableUnionCell<T>(init: T): [() => T, NullableUnionSetter<T>] {
	let cur: T = init;
	return [
		() => cur,
		(v: T | ((prev: T) => T)) => {
			if (typeof v === "function") { cur = (v as (prev: T) => T)(cur); } else { cur = v as T; }
		},
	];
}

function nullableUnionFlat(v: string | null | ((p: string) => string)): string {
	if (v === null) return "null";
	if (typeof v === "string") return "s:" + v;
	return "f:" + v("x");
}

function nullableUnionNested(v: (string | null) | ((p: NullableUnionN) => NullableUnionN)): string {
	if (v === null) return "null";
	if (typeof v === "string") return "s:" + v;
	const r = v("x");
	return r === null ? "f:null" : "f:" + r;
}

function nullableUnionPrim(v: number | string | null): string {
	if (v === null) return "null";
	if (typeof v === "string") return "s:" + v;
	return "n:" + v;
}

function nullableUnionRest(v: string | null | ((p: string) => string)): string {
	if (typeof v === "function") return "fn";
	const w: string | null = v;
	return w === null ? "wnull" : "w:" + w;
}

function nullableUnionArr(v: string | number[] | null): string {
	if (v === null) return "null";
	if (typeof v === "string") return "s:" + v;
	return "n" + v.length;
}

interface NullableUnionBox { v: string | null | ((p: string) => string); }

test "unionUpdates: typeof function selects the updater branch" {
	assert typeofProjectionApply(5, 1) == 5;
	assert typeofProjectionApply((p: int32) => p + 1, 1) == 2;
}

test "unionUpdates: typeof function narrows in a generic body" {
	assert applyUpdate<int32>(5, 1) == 5;
	assert applyUpdate<int32>((p: int32) => p * 10, 3) == 30;
}

test "unionUpdates: the negated guard excludes the callable member" {
	assert typeofProjectionNotFn(4) == 5;
	assert typeofProjectionNotFn(() => 9) == 9;
}

test "unionUpdates: a narrowed primitive member is read as an operand" {
	assert typeofProjectionPick(41) == 42;
	assert typeofProjectionPick("abc") == 3;
}

test "unionUpdates: a chain of typeof guards narrows through the residual union" {
	assert typeofProjectionChain(true) == 1;
	assert typeofProjectionChain(21) == 42;
	assert typeofProjectionChain("abcd") == 4;
}

test "unionUpdates: typeof object selects the struct member" {
	const p: TypeofProjectionPoint = { x: 3 };
	assert typeofProjectionUnwrap(p) == 3;
	assert typeofProjectionUnwrap(7) == 7;
}

test "unionUpdates: a closure with a captured environment survives the union" {
	let hits = 0;
	const bump = (p: int32) => { hits += 1; return p + 100; };
	assert typeofProjectionApply(bump, 1) == 101;
	assert typeofProjectionApply(bump, 2) == 102;
	assert hits == 2;
}

test "unionUpdates: an array literal is wrapped into the union slot" {
	assert arrayUnionLen([1, 2, 3]) == 3;
	assert arrayUnionLen(7) == 7;
}

test "unionUpdates: an array variable is wrapped into the union slot" {
	const xs: int32[] = [4, 5];
	assert arrayUnionLen(xs) == 2;
	assert xs.length == 2;
}

test "unionUpdates: a value-or-updater setter shape carries an array through both branches" {
	const next: int32[] = applyUpdate<int32[]>([1, 2, 3], []);
	assert arrayUnionTotal(next) == 6;
	const grown: int32[] = applyUpdate<int32[]>((prev: int32[]) => [prev.length, prev.length], [9, 9, 9]);
	assert arrayUnionTotal(grown) == 6;
}

test "unionUpdates: an unannotated updater arrow reaches an int32 cell" {
	const [get, set] = contextualCellCell<int32>(0);
	set(c => c + 1);
	assert get() == 1;
	set(5);
	set(c => c * 10);
	assert get() == 50;
}

test "unionUpdates: an array cell takes an array literal and an updater" {
	const [get, set] = contextualCellCell<number[]>([]);
	set([1, 2]);
	assert get().length == 2;
	set(prev => [prev.length, prev.length, prev.length]);
	assert get().length == 3;
	assert get()[0] == 2;
	set([]);
	assert get().length == 0;
}

test "unionUpdates: a string cell takes a literal and a capturing updater" {
	const [get, set] = contextualCellCell<string>("a");
	set("b");
	assert get() == "b";
	const suffix = "!";
	set(s => s + suffix);
	assert get() == "b!";
}

test "unionUpdates: an alias instance array goes through a generic method" {
	const [get, set] = aliasCellMk();
	const xs: AliasCellSetter<number>[] = [set, set];
	const ys = xs.slice(0, 1);
	assert ys.length == 1;
	ys[0](2.5);
	assert get() == 2.5;
}

test "unionUpdates: a nullable alias-over-function field is stored and called" {
	const [get, set] = aliasCellMk();
	const cell: AliasCellCell = { setter: null };
	cell.setter = set;
	if (cell.setter !== null) { cell.setter(4.5); }
	assert get() == 4.5;
	if (cell.setter !== null) { cell.setter(p => p * 2); }
	assert get() == 9;
}

test "unionUpdates: a nested or aliased nullable member accepts its payload" {
	assert nullableUnionNested("b") == "s:b";
	assert nullableUnionNested(null) == "null";
	assert nullableUnionNested((p: NullableUnionN) => p) == "f:x";
}

test "unionUpdates: a nullable union with a function member carries every arm" {
	const suffix = "1";
	assert nullableUnionFlat("b") == "s:b";
	assert nullableUnionFlat(null) == "null";
	assert nullableUnionFlat((p: string) => p + suffix) == "f:x1";
}

test "unionUpdates: a narrowed read projects the payload member" {
	assert nullableUnionPrim(null) == "null";
	assert nullableUnionPrim("a") == "s:a";
	assert nullableUnionPrim(2) == "n:2";
}

test "unionUpdates: the false typeof branch keeps a nullable payload" {
	assert nullableUnionRest("b") == "w:b";
	assert nullableUnionRest(null) == "wnull";
	assert nullableUnionRest((p: string) => p) == "fn";
}

test "unionUpdates: an array literal takes its type through the nullable payload" {
	assert nullableUnionArr([1, 2]) == "n2";
	assert nullableUnionArr("s") == "s:s";
	assert nullableUnionArr(null) == "null";
}

test "unionUpdates: a nullable string cell takes values, null and updaters" {
	const [get, set] = nullableUnionCell<string | null>("a");
	set("b");
	assert get() == "b";
	set(null);
	assert get() == null;
	set((p: string | null) => p === null ? "fromnull" : p + "!");
	assert get() == "fromnull";
	set((p: string | null) => p === null ? "again" : p + "!");
	assert get() == "fromnull!";
}

test "unionUpdates: a reassigned local and a copied field keep their payload" {
	const tag = "?";
	let x: string | null | ((p: string) => string) = "v";
	assert nullableUnionFlat(x) == "s:v";
	x = null;
	assert nullableUnionFlat(x) == "null";
	x = (p: string) => p + tag;
	assert nullableUnionFlat(x) == "f:x?";
	const a: NullableUnionBox = { v: (p: string) => p + tag };
	const b: NullableUnionBox = { v: a.v };
	a.v = "s" + tag;
	assert nullableUnionFlat(a.v) == "s:s?";
	assert nullableUnionFlat(b.v) == "f:x?";
}
