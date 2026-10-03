type Either<L, R> = match (ok: boolean) {
	true => { value: R },
	false => { error: L },
};

function eitherDiv(a: float64, b: float64): Either<string, float64> {
	if (b == 0) return { ok: false, error: "div0" };
	return { ok: true, value: a / b };
}

function resultDiv(a: float64, b: float64): Result<float64, string> {
	if (b == 0) return Result.err("div0");
	return Result.ok(a / b);
}

enum ReferenceKind { Ok, Err }

type ReferenceBody<T, E> = match (kind: ReferenceKind) {
	ReferenceKind.Ok => { value: T },
	ReferenceKind.Err => { error: E },
};

type VariantRef<T, E> = Ref<ReferenceBody<T, E>>;

function numericReference(value: float64): VariantRef<float64, string> { return { kind: ReferenceKind.Ok, value: value }; }

function textError(error: string): VariantRef<float64, string> { return { kind: ReferenceKind.Err, error: error }; }

type PayloadBody<T, E> = match (kind: ReferenceKind) {
	ReferenceKind.Ok => { value: T },
	ReferenceKind.Err => { error: E },
};

type PayloadRef<T, E> = Ref<PayloadBody<T, E>>;

function textPayload(value: string): PayloadRef<string, float64> {
	return { kind: ReferenceKind.Ok, value: value };
}

function numericFailure(error: float64): PayloadRef<string, float64> {
	return { kind: ReferenceKind.Err, error: error };
}

class Box<T> {
	items: T[];
	constructor(initial: T[]) { this.items = initial; }
}

function getBox(): Box<string> {
	return new Box<string>(["a", "b"]);
}

function safeDiv(a: number, b: number): Result<number, string> {
	if (b == 0) return Result.err("zero");
	return Result.ok(a / b);
}

import "./fixtures/privateGeneric";

function pendingDedup<T>(x: T | null): int32 {
	return 2;
}

type NamedArgument = { name: string };

type TaggedArgument = { tag: string };

function wrapArgument<T>(value: T): Result<T, string> { return Result.ok(value); }

function dup<T>(x: T) { return x; }

function pickSecond<T>(a: T, b: T) { return b; }

import "./fixtures/explicitTypeArguments";

interface ModuleArgumentsErr { msg: string; }

function moduleArgumentsFail(): Result<string, ModuleArgumentsErr> {
	return Result.err({ msg: "leak" });
}

function moduleArgumentsOk(): Result<int32, ModuleArgumentsErr> {
	const n: int32 = 3;
	return Result.ok(n);
}

test "nominalInstantiation: nominal unions with identical shapes preserve both active payloads" {
	for (const divisor of [4.0, 0.0]) {
		const either = eitherDiv(20, divisor);
		const result = resultDiv(20, divisor);
		assert either.ok == (divisor != 0);
		assert result.ok == either.ok;
		if (either.ok) assert either.value == 5;
		else assert either.error == "div0";
		if (result.ok) assert result.value == 5;
		else assert result.error == "div0";
	}
}

test "nominalInstantiation: reference-wrapped generic variants retain the substituted payload in each arm" {
	const n = numericReference(99);
	const e = textError("boom");
	assert n.kind == ReferenceKind.Ok;
	assert e.kind == ReferenceKind.Err;
	if (n.kind == ReferenceKind.Ok) assert n.value == 99;
	if (e.kind == ReferenceKind.Err) assert e.error == "boom";
}

test "nominalInstantiation: a reference-wrapped variant reads and destroys a string payload" {
	const ok = textPayload("hello-payload");
	const err = numericFailure(42);
	assert ok.kind == ReferenceKind.Ok;
	assert err.kind == ReferenceKind.Err;
	if (ok.kind == ReferenceKind.Ok) assert ok.value == "hello-payload";
	if (err.kind == ReferenceKind.Err) assert err.error == 42;
}

test "nominalInstantiation: generic class field type substitutes through typeReturn" {

	const b = getBox();
	const arr = b.items;
	assert arr.length == 2;
	assert arr[0] == "a";
}

test "nominalInstantiation: narrowed variant field has concrete error type" {

	const r = safeDiv(10, 0);
	assert !r.ok;
	if (!r.ok) {
		assert r.error == "zero";
	}
}

test "nominalInstantiation: numeric literal contextual T binds correctly" {

	function f(): Result<number, string> {
		let r = 0;
		return Result.ok(r - 1);
	}
	const got = f();
	assert got.ok;
	if (got.ok) {
		assert got.value == -1;
	}
}

test "nominalInstantiation: the second module runs its OWN body, not the first module's" {
	const a: int32 | null = null;
	const b: int64 | null = null;
	assert pendingDedup(a) == 2;
	assert pendingDedup(b) == 2;
}

test "nominalInstantiation: generic instances keep distinct structural fields and repeated instance payloads" {
	const named = wrapArgument<NamedArgument>({ name: "first" });
	const tagged = wrapArgument<TaggedArgument>({ tag: "second" });
	const repeated = wrapArgument<NamedArgument>({ name: "third" });
	assert named.ok && tagged.ok && repeated.ok;
	if (named.ok) assert named.value.name == "first";
	if (tagged.ok) assert tagged.value.tag == "second";
	if (repeated.ok) assert repeated.value.name == "third";
}

test "nominalInstantiation: mono instance adopts the inferred return type" {
	const n = dup<int32>(42);
	assert n == 42;
	const s = dup<string>("hey");
	assert s == "hey";
}

test "nominalInstantiation: inferred return flows through multi-param generics" {
	const v = pickSecond<float64>(1.5, 2.5);
	assert v == 2.5;
}

test "nominalInstantiation: a sibling module's type args never reach this Result.err" {
	const r = moduleArgumentsFail();
	assert !r.ok;
	assert r.error.msg == "leak";
}

test "nominalInstantiation: a sibling module's new-expression type args never reach this Result.ok" {
	const r = moduleArgumentsOk();
	assert r.ok;
	assert r.value == 3;
}

const moduleLimit: int32 = 10;
struct ModulePayload { n: int32; }
function moduleClamp<T>(value: T, n: int32): int32 { return n > moduleLimit ? moduleLimit : n; }
function moduleMake<T>(value: T): ModulePayload { const payload: ModulePayload = { n: 7 }; return payload; }
function moduleInner<U>(value: U): int32 { const payload: ModulePayload = { n: 4 }; return payload.n; }
function moduleOuter<ModulePayload>(value: ModulePayload): int32 { return moduleInner(value); }
function moduleParameter(moduleLimit: string): int32 { return moduleClamp(5 as int64, 42); }
class ModuleCounter<T> {
	total: int32 = 0;
	constructor(value: T) { this.total = moduleLimit; }
}
class ModuleHolder<T> { get(): int32 { return moduleLimit; } }

test "nominalInstantiation: generic bodies resolve module values independently of caller binding scopes" {
	const moduleLimit: string = "caller";
	assert moduleClamp(1 as int32, 42) == 10;
	if (true) {
		const moduleLimit: int32 = 99;
		assert moduleClamp("s", 42) == 10;
	}
	if (true) {
		const moduleLimit: string = "block";
		assert moduleClamp(true, 42) == 10;
	}
	for (const moduleLimit of ["loop"]) assert moduleClamp(1.5, 42) == 10;
	const fromArrow = (moduleLimit: string): int32 => moduleClamp(7 as uint8, 42);
	assert fromArrow("arrow") == 10;
	assert moduleParameter("parameter") == 10;
	assert new ModuleCounter<int32>(1).total == 10;
	assert new ModuleHolder<boolean>().get() == 10;
}

test "nominalInstantiation: caller values and outer type parameters cannot capture generic body type names" {
	const ModulePayload = 3;
	assert moduleMake(2 as int16).n == 7;
	assert moduleOuter("nested") == 4;
}
