type N177 = string | null;
type Setter177<T> = (v: T | ((prev: T) => T)) => void;

function cell177<T>(init: T): [() => T, Setter177<T>] {
	let cur: T = init;
	return [
		() => cur,
		(v: T | ((prev: T) => T)) => {
			if (typeof v === "function") { cur = (v as (prev: T) => T)(cur); } else { cur = v as T; }
		},
	];
}

function flat177(v: string | null | ((p: string) => string)): string {
	if (v === null) return "null";
	if (typeof v === "string") return "s:" + v;
	return "f:" + v("x");
}

function nested177(v: (string | null) | ((p: N177) => N177)): string {
	if (v === null) return "null";
	if (typeof v === "string") return "s:" + v;
	const r = v("x");
	return r === null ? "f:null" : "f:" + r;
}

function prim177(v: number | string | null): string {
	if (v === null) return "null";
	if (typeof v === "string") return "s:" + v;
	return "n:" + v;
}

function rest177(v: string | null | ((p: string) => string)): string {
	if (typeof v === "function") return "fn";
	const w: string | null = v;
	return w === null ? "wnull" : "w:" + w;
}

function arr177(v: string | number[] | null): string {
	if (v === null) return "null";
	if (typeof v === "string") return "s:" + v;
	return "n" + v.length;
}

interface Box177 { v: string | null | ((p: string) => string); }

test "a nested or aliased nullable member accepts its payload" {
	assert nested177("b") == "s:b";
	assert nested177(null) == "null";
	assert nested177((p: N177) => p) == "f:x";
}

test "a nullable union with a function member carries every arm" {
	const suffix = "1";
	assert flat177("b") == "s:b";
	assert flat177(null) == "null";
	assert flat177((p: string) => p + suffix) == "f:x1";
}

test "a narrowed read projects the payload member" {
	assert prim177(null) == "null";
	assert prim177("a") == "s:a";
	assert prim177(2) == "n:2";
}

test "the false typeof branch keeps a nullable payload" {
	assert rest177("b") == "w:b";
	assert rest177(null) == "wnull";
	assert rest177((p: string) => p) == "fn";
}

test "an array literal takes its type through the nullable payload" {
	assert arr177([1, 2]) == "n2";
	assert arr177("s") == "s:s";
	assert arr177(null) == "null";
}

test "a nullable string cell takes values, null and updaters" {
	const [get, set] = cell177<string | null>("a");
	set("b");
	assert get() == "b";
	set(null);
	assert get() == null;
	set((p: string | null) => p === null ? "fromnull" : p + "!");
	assert get() == "fromnull";
	set((p: string | null) => p === null ? "again" : p + "!");
	assert get() == "fromnull!";
}

test "a reassigned local and a copied field keep their payload" {
	const tag = "?";
	let x: string | null | ((p: string) => string) = "v";
	assert flat177(x) == "s:v";
	x = null;
	assert flat177(x) == "null";
	x = (p: string) => p + tag;
	assert flat177(x) == "f:x?";
	const a: Box177 = { v: (p: string) => p + tag };
	const b: Box177 = { v: a.v };
	a.v = "s" + tag;
	assert flat177(a.v) == "s:s?";
	assert flat177(b.v) == "f:x?";
}
