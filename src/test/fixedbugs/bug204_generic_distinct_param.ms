// Symptom: a generic `distinct` instance passed as a plain parameter failed with "Argument type mismatch … expected Wrap<T>".
// Root cause: the call's argument loop checked the argument against the unbound formal; only an object literal waited for binding.
// Fix: every argument whose formal still has generic parameters waits for the post-binding check in `tryInstantiateGenericCallee`.

struct Box204<T> { v: T; }
type Wrap204<T> = distinct T;
type Thunk204<T> = distinct (() => T);
type Boxed204<T> = distinct Box204<T>;
type Inner204<T> = distinct T;
type Outer204<T> = Inner204<T>;

function peel204<T>(w: Wrap204<T>): T { return w as T; }
function call204<T>(t: Thunk204<T>): T { const f = t as (() => T); return f(); }
function unbox204<T>(b: Boxed204<T>): T { const x = b as Box204<T>; return x.v; }
function deep204<T>(o: Outer204<T>): T { return o as T; }
function pair204<T, U>(a: Wrap204<T>, b: Wrap204<U>): U { return b as U; }

test "bug204: generic distinct parameter binds from its argument" {
	const a = 5 as Wrap204<int32>;
	assert peel204(a) == 5;
	assert peel204<int32>(a) == 5;
}

test "bug204: distinct over a function type and over a generic struct" {
	const t = (() => 7) as Thunk204<int32>;
	assert call204(t) == 7;
	const bx: Box204<int32> = { v: 9 };
	assert unbox204(bx as Boxed204<int32>) == 9;
}

test "bug204: distinct through a second alias and two type parameters" {
	assert deep204(11 as Outer204<int32>) == 11;
	assert pair204(5 as Wrap204<int32>, "x" as Wrap204<string>) == "x";
}
