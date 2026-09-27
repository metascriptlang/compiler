type DistinctCallableThunk<T> = distinct (() => T);

type DistinctCallableTh = distinct (() => number);

interface DistinctCallableBox { f: DistinctCallableThunk<number>; }

function distinctCallableKeep(x: DistinctCallableThunk<number>): DistinctCallableThunk<number> { const y: DistinctCallableThunk<number> = x; return y; }

function distinctCallableMake(n: number): DistinctCallableThunk<number> { return (() => n) as DistinctCallableThunk<number>; }

interface SignatureArgumentHost { n: int32; }

function signatureArgumentMk(v: int32): (x: int32) => SignatureArgumentHost {
	return (x) => ({ n: x + v });
}

function doubleNumber(x: number): number { return x * 2; }

function tripleNumber(x: number): number { return x * 3; }

function namedCarrierTakeMaybe(f: ((x: number) => number) | null): number {
	if (f === null) { return -1; }
	return f(5);
}

function namedCarrierPick(flag: boolean): ((x: number) => number) | null {
	if (flag) { return doubleNumber; }
	return null;
}

function namedCarrierTakeG<T>(v: T, f: ((x: T) => T) | null): T {
	if (f !== null) { return f(v); }
	return v;
}

interface NamedCarrierBox { f: ((x: number) => number) | null; }

function namedCarrierTakeBox(b: NamedCarrierBox): number { return namedCarrierTakeMaybe(b.f); }

const namedCarrierModuleSlot: ((x: number) => number) | null = tripleNumber;

type NamedCarrierMount = (tag: string, depth: number) => number;

function namedCarrierMount(tag: string, depth: number): number { return tag.length + depth; }

interface NamedCarrierProps { children: NamedCarrierMount | null; }

function namedCarrierRender(p: NamedCarrierProps): number {
	if (p.children !== null) { return p.children("ab", 3); }
	return -1;
}

function inferredStorageId<T>(x: T): T { return x; }

function inferredStorageOnly() { return doubleNumber; }

function inferredStoragePick(flag: boolean) {
	if (flag) { return doubleNumber; }
	return tripleNumber;
}

function inferredStorageTakePlain(f: (x: number) => number): number { return f(5); }

test "functionCarriers: a non-generic distinct thunk is callable" {
	const t = (() => 7) as DistinctCallableTh;
	assert t() == 7;
}

test "functionCarriers: a generic distinct thunk is callable with the substituted return type" {
	const t = (() => 7) as DistinctCallableThunk<number>;
	const n: number = t();
	assert n == 7;
}

test "functionCarriers: the distinct thunk widens to its base function type" {
	const t = (() => 7) as DistinctCallableThunk<number>;
	const f: () => number = t;
	assert f() == 7;
}

test "functionCarriers: a copied generic distinct thunk links and runs" {
	const t = distinctCallableMake(8);
	const u = distinctCallableKeep(t);
	assert u() == 8;
	assert t() == 8;
}

test "functionCarriers: a struct field of distinct thunk type is copied and called through the member" {
	const b: DistinctCallableBox = { f: distinctCallableMake(9) };
	const c = b;
	assert c.f() == 9;
	assert b.f() == 9;
}

test "functionCarriers: an array of distinct thunks is iterated and called" {
	const xs: DistinctCallableThunk<number>[] = [distinctCallableMake(1), distinctCallableMake(2)];
	let sum: number = 0;
	for (const x of xs) sum = sum + x();
	assert sum == 3;
}

test "functionCarriers: a captured closure survives through the distinct wrapper" {
	let hits: number = 0;
	const t = (() => { hits = hits + 1; return hits; }) as DistinctCallableThunk<number>;
	t();
	t();
	assert hits == 2;
}

test "functionCarriers: a std generic bound to a function type resolves the types inside its signature" {
	const fns: ((x: int32) => SignatureArgumentHost)[] = [signatureArgumentMk(1), signatureArgumentMk(2)];
	const same = fns.map((f, i) => f);
	assert same.length == 2;
	assert same[0](10).n == 11;
	assert same[1](10).n == 12;
}

test "functionCarriers: a function type nested in an array argument resolves too" {
	const pairs: ((x: int32) => SignatureArgumentHost)[][] = [[signatureArgumentMk(5)]];
	const heads = pairs.map((p, i) => p[0]);
	assert heads.length == 1;
	assert heads[0](1).n == 6;
}

test "functionCarriers: a named function into a module-level nullable function constant" {
	assert namedCarrierTakeMaybe(namedCarrierModuleSlot) === 15;
}

test "functionCarriers: a named function into a nullable function declaration, assignment and return" {
	const h: ((x: number) => number) | null = doubleNumber;
	assert namedCarrierTakeMaybe(h) === 10;
	let g: ((x: number) => number) | null = null;
	assert namedCarrierTakeMaybe(g) === -1;
	g = tripleNumber;
	assert namedCarrierTakeMaybe(g) === 15;
	assert namedCarrierTakeMaybe(namedCarrierPick(true)) === 10;
	assert namedCarrierTakeMaybe(namedCarrierPick(false)) === -1;
}

test "functionCarriers: a named function as a call argument into a nullable function parameter" {
	assert namedCarrierTakeMaybe(doubleNumber) === 10;
	assert namedCarrierTakeG(4.0, doubleNumber) === 8;
}

test "functionCarriers: a named function in a ternary arm, an object field and an array element" {
	const flag = namedCarrierTakeMaybe(null) < 0;
	const t: ((x: number) => number) | null = flag ? tripleNumber : null;
	assert namedCarrierTakeMaybe(t) === 15;
	const b: NamedCarrierBox = { f: doubleNumber };
	assert namedCarrierTakeMaybe(b.f) === 10;
	assert namedCarrierTakeBox({ f: tripleNumber }) === 15;
	const xs: (((x: number) => number) | null)[] = [doubleNumber, null];
	assert namedCarrierTakeMaybe(xs[0]) === 10;
	assert namedCarrierTakeMaybe(xs[1]) === -1;
}

test "functionCarriers: a named function into a union with a function member" {
	const u: ((x: number) => number) | string = doubleNumber;
	let got: number = -1;
	if (typeof u === "function") { got = u(7); }
	assert got === 14;
}

test "functionCarriers: a named function into a nullable alias of a function type" {
	const m: NamedCarrierMount | null = namedCarrierMount;
	assert namedCarrierRender({ children: m }) === 5;
	assert namedCarrierRender({ children: namedCarrierMount }) === 5;
	assert namedCarrierRender({ children: null }) === -1;
}

test "functionCarriers: closure values into the carrier keep running" {
	const k: number = 100;
	const c = (x: number): number => x + k;
	const h: ((x: number) => number) | null = c;
	assert namedCarrierTakeMaybe(h) === 105;
	assert namedCarrierTakeMaybe((x: number): number => x - 1) === 4;
	const plain: (x: number) => number = doubleNumber;
	assert namedCarrierTakeMaybe(plain) === 10;
}

test "functionCarriers: a named function in an inferred object field and array element" {
	const o = { f: doubleNumber };
	assert o.f(5) === 10;
	assert inferredStorageTakePlain(o.f) === 10;
	const one = [tripleNumber];
	assert one[0](5) === 15;
	const two = [doubleNumber, tripleNumber];
	assert inferredStorageTakePlain(two[1]) === 15;
}

test "functionCarriers: a named function through an inferred return" {
	assert inferredStorageOnly()(5) === 10;
	assert inferredStorageTakePlain(inferredStorageOnly()) === 10;
	assert inferredStoragePick(true)(5) === 10;
	assert inferredStoragePick(false)(5) === 15;
	const mk = () => tripleNumber;
	assert mk()(5) === 15;
}

test "functionCarriers: a named function through a generic binding and an inferred ternary" {
	const g = inferredStorageId(doubleNumber);
	assert g(5) === 10;
	const flag = inferredStorageTakePlain(doubleNumber) > 0;
	const t = flag ? tripleNumber : doubleNumber;
	assert t(5) === 15;
}

test "functionCarriers: an inferred function local still reassigns" {
	let f = doubleNumber;
	assert f(5) === 10;
	f = tripleNumber;
	assert f(5) === 15;
}
