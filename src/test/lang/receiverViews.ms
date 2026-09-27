import { Item, makeItem } from "./fixtures/enumField";

enum Shade { Dark, Light }

struct GenericViewBox<T> { value: T; }

class GenericViewPet { hunger: int32 = 3; }

function genericViewPut<T>(ref box: GenericViewBox<T>, v: T): void { box.value = v; }

function genericViewPeek<T>(ref box: GenericViewBox<T>): T { return box.value; }

function genericViewSet<T>(ref x: T, v: T): void { x = v; }

function genericViewFill<T>(out box: GenericViewBox<T>, v: T): void { box = { value: v }; }

function genericViewSeen<T>(b: Borrow<T>): boolean { return b != null; }

function genericViewIsSet<T>(c: Cursor<T>): boolean { return c != null; }

import { ImportedStance, cost } from "./fixtures/enumExtension";

enum EnumReceiverMood { Calm, Angry }

struct EnumReceiverPet { mood: EnumReceiverMood; hunger: int32; }

function label(this mood: EnumReceiverMood): uint8 {
	return (mood as int32) as uint8;
}

function scaled(this mood: EnumReceiverMood, factor: int32): int32 {
	return ((mood as int32) + 1) * factor;
}

function enumReceiverLabelOf(mood: EnumReceiverMood): uint8 {
	return mood.label();
}

import { ImportedPoint, readImportedPoint } from "./fixtures/receiverExtension";

struct ReceiverValue { n: int32; }

type ReceiverObject = { n: int32 };

class ReceiverClass { n: int32 = 10; }

struct ReceiverContainer { s: ReceiverValue; }

function get(this x: ReceiverValue): int32 { return x.n; }

function getO(this x: ReceiverObject): int32 { return x.n; }

function getC(this x: ReceiverClass): int32 { return x.n; }

function same<T>(this x: T): T { return x; }

function bump(this ref x: ReceiverValue): void { x.n = x.n + 1; }

function bumpTwice(ref p: ReceiverValue): void { p.bump(); p.bump(); }

function inc(this x: ReceiverValue): ReceiverValue { return { n: x.n + 1 }; }

class ReceiverSubclass extends ReceiverClass { m: int32 = 1; }

class ReadonlyViewBox<T> { v: T; constructor(v: T) { this.v = v; } }

function readonlyViewPeekFree<T>(b: Readonly<ReadonlyViewBox<T>>): T { return b.v; }

function readonlyViewPeek<T>(this b: Readonly<ReadonlyViewBox<T>>): T { return b.v; }

function readonlyViewViaView(b: Readonly<ReadonlyViewBox<int32>>): int32 { return readonlyViewPeekFree(b) + b.readonlyViewPeek(); }

test "receiverViews: enum reverse index on enum-typed operand" {
	const s: Shade = Shade.Light;
	assert Shade[s] == "Light";
	assert Shade[Shade.Dark] == "Dark";
}

test "receiverViews: enum reverse index on int32 operand" {
	const i: int32 = 1;
	assert Shade[i] == "Light";
}

test "receiverViews: enum reverse index out of range" {
	const i: int32 = 9;
	assert Shade[i] == "<unknown>";
}

test "receiverViews: toString on enum reached only through an imported field type" {
	const it: Item = makeItem();
	assert it.grade.toString() == "Good";
}

test "receiverViews: a generic ref parameter binds T from the argument" {
	let box: GenericViewBox<int32> = { value: 1 };
	genericViewPut(box, 5);
	assert box.value == 5;
	assert genericViewPeek(box) == 5;
	let label: GenericViewBox<string> = { value: "a" };
	genericViewPut(label, "b");
	assert label.value == "b";
}

test "receiverViews: an explicit type argument substitutes inside a ref parameter" {
	let box: GenericViewBox<int32> = { value: 1 };
	genericViewPut<int32>(box, 7);
	assert box.value == 7;
}

test "receiverViews: a bare generic ref parameter writes through" {
	let n: int32 = 1;
	genericViewSet(n, 5);
	assert n == 5;
}

test "receiverViews: a generic out parameter binds T" {
	let box: GenericViewBox<int32> = { value: 1 };
	genericViewFill(box, 9);
	assert box.value == 9;
}

test "receiverViews: generic Borrow and Cursor parameters bind T" {
	const pet = new GenericViewPet();
	const borrowed: Borrow<GenericViewPet> = pet;
	const cursor: Cursor<GenericViewPet> = pet;
	assert genericViewSeen(borrowed);
	assert genericViewSeen(pet);
	assert genericViewIsSet(cursor);
	assert genericViewIsSet(pet);
}

test "receiverViews: extension on an enum local and an enum literal" {
	const mood = EnumReceiverMood.Angry;
	assert mood.label() == 1;
	assert EnumReceiverMood.Angry.label() == 1;
	assert EnumReceiverMood.Calm.label() == 0;
}

test "receiverViews: extension on an enum parameter and a struct field" {
	const pet: EnumReceiverPet = { mood: EnumReceiverMood.Angry, hunger: 3 };
	assert enumReceiverLabelOf(EnumReceiverMood.Calm) == 0;
	assert pet.mood.label() == 1;
	assert pet.mood.scaled(5) == 10;
}

test "receiverViews: extension on an imported enum" {
	const stance = ImportedStance.Rest;
	assert stance.cost(10) == 12;
	assert ImportedStance.Strike.cost(1) == 2;
}

test "receiverViews: a struct receiver reads the same as the free call" {
	const v: ReceiverValue = { n: 10 };
	assert v.get() == get(v);
	assert v.get() == 10;
}

test "receiverViews: object type, class and generic receivers read the same as the free call" {
	const o: ReceiverObject = { n: 11 };
	const c = new ReceiverClass();
	const k: int32 = 12;
	assert o.getO() == getO(o) && o.getO() == 11;
	assert c.getC() == getC(c) && c.getC() == 10;
	assert k.same() == same(k) && k.same() == 12;
}

test "receiverViews: a Ref<T> receiver on a T extension behaves like the free call" {
	const r: Ref<ReceiverValue> = { n: 13 };
	assert r.get() == get(r);
	assert r.get() == 13;
}

test "receiverViews: an imported extension and a chained call" {
	const p: ImportedPoint = { n: 14 };
	assert p.readImportedPoint() == readImportedPoint(p) && p.readImportedPoint() == 14;
	const v: ReceiverValue = { n: 8 };
	assert v.inc().inc().get() == 10;
}

test "receiverViews: a subclass receiver reads the same as the free call" {
	const d = new ReceiverSubclass();
	assert d.getC() == getC(d);
	assert d.getC() == 10;
}

test "receiverViews: a this ref receiver writes through a let, a field and an element" {
	let v: ReceiverValue = { n: 10 };
	v.bump();
	assert v.n == 11;
	let w: ReceiverContainer = { s: { n: 20 } };
	w.s.bump();
	assert w.s.n == 21;
	let xs: ReceiverValue[] = [{ n: 1 }, { n: 30 }];
	xs[1].bump();
	assert xs[1].n == 31;
}

test "receiverViews: a this ref receiver passes a ref parameter on" {
	let v: ReceiverValue = { n: 10 };
	bumpTwice(v);
	assert v.n == 12;
	bump(v);
	assert v.n == 13;
}

test "receiverViews: a generic Readonly formal accepts a view, free and method form" {
	const b = new ReadonlyViewBox<int32>(5);
	assert readonlyViewViaView(b) == 10;
	assert readonlyViewPeekFree(b) == 5;
	assert b.readonlyViewPeek() == 5;
}

test "receiverViews: a generic Readonly formal binds a string payload" {
	const b = new ReadonlyViewBox<string>("x");
	assert readonlyViewPeekFree(b) == "x";
	assert b.readonlyViewPeek() == "x";
}

struct StaticPet { a: uint8; }
struct StaticBlock { b: uint8; }
enum StaticKind { Plain, Fancy }
class StaticTag { static tag(): int32 { return 5; } }

function accountKind(this typeof StaticPet): uint8 { return 2; }
function accountKind(this typeof StaticBlock): uint8 { return 1; }
function first(this typeof StaticKind): StaticKind { return StaticKind.Fancy; }
function kindOf<T>(): uint8 { return T.accountKind(); }
function kindThrough<U>(): uint8 { return kindOf<U>(); }
function kindOfValue<T>(value: T): uint8 { return T.accountKind(); }
function firstOf<T>(): T { return T.first(); }
function tagOf<T>(): int32 { return T.tag(); }

enum StaticMood { Calm, Angry }
function fromByte(this typeof StaticMood, value: uint8): StaticMood { return (value as int32) as StaticMood; }
function first(this typeof StaticMood): StaticMood { return StaticMood.Calm; }
function Calm(this typeof StaticMood): int32 { return 7; }

test "receiverViews: generic static calls bind the concrete type across inference and forwarding" {
	assert kindOf<StaticPet>() == 2;
	assert kindOf<StaticBlock>() == 1;
	assert kindThrough<StaticPet>() == 2;
	assert kindThrough<StaticBlock>() == 1;
	const pet: StaticPet = { a: 1 };
	const block: StaticBlock = { b: 1 };
	assert kindOfValue(pet) == 2 && kindOfValue(block) == 1;
	assert firstOf<StaticKind>() == StaticKind.Fancy;
	assert tagOf<StaticTag>() == 5;
}

test "receiverViews: enum static extensions coexist with members and members win name collisions" {
	assert StaticMood.fromByte(1) == StaticMood.Angry;
	assert StaticMood.fromByte(0) == StaticMood.Calm;
	assert StaticMood.first() == StaticMood.Calm;
	assert (StaticMood.Calm as int32) == 0;
}
