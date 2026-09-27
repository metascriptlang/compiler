type GenericAliasSetter<T> = (v: T) => void;

type GenericAliasBox<T> = T[];

type GenericAliasPair<T> = [T, T];

type GenericAliasPhantom<T> = int32;

type GenericAliasSame<T> = T;

interface GenericAliasCell<T> { set: GenericAliasSetter<T>; }

function genericAliasMk<T>(init: T): [() => T, GenericAliasSetter<T>] {
	let cur: T = init;
	return [() => cur, (v: T) => { cur = v; }];
}

function genericAliasWrap<T>(x: T): GenericAliasBox<T> { return [x]; }

function genericAliasPair<T>(x: T): GenericAliasPair<T> { return [x, x]; }

type DistinctValue<T> = distinct T;

type DistinctPayloadBox<T> = distinct T[];

type DistinctPayloadCnt<E> = distinct number;

interface DistinctPayloadRow { name: DistinctValue<string>; n: DistinctValue<int32>; }

function distinctPayloadBump(w: DistinctValue<int32>): DistinctValue<int32> { return ((w as int32) + 1) as DistinctValue<int32>; }

function distinctPayloadInc(x: DistinctPayloadCnt<string>): DistinctPayloadCnt<string> { return ((x as number) + 1) as DistinctPayloadCnt<string>; }

struct DistinctInferenceBox<T> { v: T; }

type DistinctInferenceThunk<T> = distinct (() => T);

type DistinctInferenceBoxed<T> = distinct DistinctInferenceBox<T>;

type DistinctInferenceInner<T> = distinct T;

type DistinctInferenceOuter<T> = DistinctInferenceInner<T>;

function distinctInferencePeel<T>(w: DistinctValue<T>): T { return w as T; }

function distinctInferenceCall<T>(t: DistinctInferenceThunk<T>): T { const f = t as (() => T); return f(); }

function distinctInferenceUnbox<T>(b: DistinctInferenceBoxed<T>): T { const x = b as DistinctInferenceBox<T>; return x.v; }

function distinctInferenceDeep<T>(o: DistinctInferenceOuter<T>): T { return o as T; }

function distinctInferencePair<T, U>(a: DistinctValue<T>, b: DistinctValue<U>): U { return b as U; }

test "aliasRepresentation: a generic alias over a function type is a callable variable" {
	let got: int32 = 0;
	const s: GenericAliasSetter<int32> = (v: int32) => { got = v; };
	s(5);
	assert got == 5;
}

test "aliasRepresentation: a generic alias over a function type returns in a tuple from a generic function" {
	const [get, set] = genericAliasMk<int32>(1);
	set(7);
	assert get() == 7;
}

test "aliasRepresentation: a generic alias over a function type is an interface field" {
	let got: int32 = 0;
	const c: GenericAliasCell<int32> = { set: (v: int32) => { got = v; } };
	c.set(9);
	assert got == 9;
}

test "aliasRepresentation: a generic alias over a function type copies through a struct and an array" {
	let got: int32 = 0;
	const c: GenericAliasCell<int32> = { set: (v: int32) => { got = got + v; } };
	const d = c;
	const arr: GenericAliasSetter<int32>[] = [c.set, d.set];
	for (const f of arr) f(2);
	assert got == 4;
}

test "aliasRepresentation: a generic alias over an array type returns from a generic function" {
	const xs: GenericAliasBox<int32> = genericAliasWrap<int32>(3);
	assert xs.length == 1;
	assert xs[0] == 3;
}

test "aliasRepresentation: a generic alias over a tuple type indexes to the element" {
	const p: GenericAliasPair<int32> = genericAliasPair<int32>(4);
	assert p[0] + p[1] == 8;
}

test "aliasRepresentation: a generic alias over a primitive stringifies as its value and adds as a number" {
	const x: GenericAliasPhantom<boolean> = 3;
	assert x.toString() == "3";
	assert (x + 1).toString() == "4";
	const y: GenericAliasSame<string> = "hi";
	assert y.length == 2;
	assert y.toString() == "hi";
}

test "aliasRepresentation: a distinct over a type parameter is passed and returned with the substituted representation" {
	const w = 5 as DistinctValue<int32>;
	const b = distinctPayloadBump(w);
	assert (b as int32) === 6;
}

test "aliasRepresentation: struct fields of a distinct over a type parameter carry the substituted representation" {
	const rows: DistinctPayloadRow[] = [{ name: "hi" as DistinctValue<string>, n: 7 as DistinctValue<int32> }, { name: "yo" as DistinctValue<string>, n: 8 as DistinctValue<int32> }];
	let total = 0;
	for (const x of rows) { total = total + (x.n as int32); }
	assert total === 15;
	assert (rows[0].name as string) === "hi";
}

test "aliasRepresentation: a distinct over an array of the type parameter iterates through its base" {
	const b = [1, 2, 3] as DistinctPayloadBox<int32>;
	const inner = b as int32[];
	let sum = 0;
	for (const v of inner) { sum = sum + v; }
	assert inner.length === 3;
	assert sum === 6;
}

test "aliasRepresentation: a phantom distinct keeps its scalar representation" {
	const c = 3 as DistinctPayloadCnt<string>;
	assert (distinctPayloadInc(c) as number) === 4;
}

test "aliasRepresentation: generic distinct parameter binds from its argument" {
	const a = 5 as DistinctValue<int32>;
	assert distinctInferencePeel(a) == 5;
	assert distinctInferencePeel<int32>(a) == 5;
}

test "aliasRepresentation: distinct over a function type and over a generic struct" {
	const t = (() => 7) as DistinctInferenceThunk<int32>;
	assert distinctInferenceCall(t) == 7;
	const bx: DistinctInferenceBox<int32> = { v: 9 };
	assert distinctInferenceUnbox(bx as DistinctInferenceBoxed<int32>) == 9;
}

test "aliasRepresentation: distinct through a second alias and two type parameters" {
	assert distinctInferenceDeep(11 as DistinctInferenceOuter<int32>) == 11;
	assert distinctInferencePair(5 as DistinctValue<int32>, "x" as DistinctValue<string>) == "x";
}
