class DefaultCounter {
	value: int32 = 0;
	add(amount: int32 = 1, scale: int32 = 1): int32 {
		this.value += amount * scale;
		return this.value;
	}
}

class DefaultGreeting {
	name: string;
	constructor(name: string) { this.name = name; }
	greet(greeting: string = "Hello"): string { return greeting + ", " + this.name; }
	wrap(value: string, suffix: string = "!"): string { return this.name + value + suffix; }
}

class ArrayMethodBox {
	count(items: string[]): int32 {
		return items.length as int32;
	}
}

class Forward {

	process(items: string[]): int32 {
		return takeArr(items);
	}
}

function takeArr(arr: string[]): int32 {
	return arr.length as int32;
}

class Reader {

	first(items: string[]): string {
		if (items.length == 0) return "";
		return items[0];
	}
}

class NumOp {

	sum(values: number[]): number {
		let total: number = 0;
		for (const v of values) {
			total = total + v;
		}
		return total;
	}
}

class CtorBox {
	count: int32;
	constructor(items: int32[]) {
		this.count = items.length as int32;
	}
}

class A1 {
	x: int32;
	constructor(x: int32) { this.x = x; }
}

class B1 extends A1 {
	y: int32;
	constructor(x: int32, y: int32) {
		super(x);
		this.y = y;
	}
}

class C1 extends B1 {
	z: int32;
	constructor(x: int32, y: int32, z: int32) {
		super(x, y);
		this.z = z;
	}
}

class StaticOps {
	static sumAll(items: int32[]): int32 {
		let total: int32 = 0;
		for (const v of items) {
			total = total + (v as int32);
		}
		return total;
	}
}

import { CrossA, CrossB } from "./fixtures/classInheritance";

class StaticFactoryBox<T> {
	v: T;
	static make(x: T): StaticFactoryBox<T> {
		const b = new StaticFactoryBox<T>();
		b.v = x;
		return b;
	}
}

class MethodOverloadBox {
	v: int32 = 0;
	describe(n: int32): string { return "int:" + n.toString(); }
	describe(s: string): string { return "str:" + s; }
	add(a: int32): int32 { return a; }
	add(a: int32, b: int32): int32 { return a + b; }
	pick(n: int32): int32 { return n + 1; }
	pick(s: string): string { return "s:" + s; }
	static make(n: int32): string { return "static-int:" + n.toString(); }
	static make(s: string): string { return "static-str:" + s; }
}

class Slot {
	static of(n: int32): string { return "static:" + n.toString(); }
	of(s: string): string { return "inst:" + s; }
}

class ConstructorInstanceBag<T> {
	items: T[];
	constructor(xs: T[]) {
		this.items = [];
		for (const x of xs) { this.add(x); }
	}
	add(x: T): void { this.items.push(x); }
	me(): ConstructorInstanceBag<T> { return this; }
}

class ConstructorInstanceIntBag<T> {
	items: int32[];
	constructor(xs: int32[]) {
		this.items = [];
		for (const x of xs) { constructorInstancePutInt(this, x); }
		const self: ConstructorInstanceIntBag<int32> = this;
		constructorInstancePutInt(self, 100);
	}
}

function constructorInstancePutInt(b: ConstructorInstanceIntBag<int32>, x: int32): void { b.items.push(x); }

class ConstructorInstancePair<K, V> {
	ks: K[];
	vs: V[];
	constructor(k: K, v: V) {
		this.ks = [];
		this.vs = [];
		constructorInstancePutPair(this, 1, "a");
		this.ks.push(k);
		this.vs.push(v);
	}
}

function constructorInstancePutPair(p: ConstructorInstancePair<int32, string>, k: int32, v: string): void { p.ks.push(k); p.vs.push(v); }

test "classCalls: method defaults fill only the omitted trailing arguments after the receiver" {
	const c = new DefaultCounter();
	assert c.add() == 1;
	assert c.add(5) == 6;
	assert c.add(3, 2) == 12;
	assert c.add(0, 9) == 12;
	const other = new DefaultCounter();
	assert other.add() == 1;
	assert c.value == 12;
}

test "classCalls: required and defaulted string arguments retain their position" {
	const g = new DefaultGreeting("world");
	assert g.greet() == "Hello, world";
	assert g.greet("Hi") == "Hi, world";
	assert g.wrap("x") == "worldx!";
	assert g.wrap("x", "?") == "worldx?";
	assert g.wrap("x", "") == "worldx";
}

test "classCalls: method with string[] param accepts named lvalue" {
	const b = new ArrayMethodBox();
	const items: string[] = ["a", "b", "c"];
	const n = b.count(items);
	assert n == 3;
}

test "classCalls: method body forwards array to standalone fn" {
	const f = new Forward();
	const items: string[] = ["x", "y"];
	const n = f.process(items);
	assert n == 2;
}

test "classCalls: method body indexes promoted array param" {
	const r = new Reader();
	const items: string[] = ["one", "two"];
	const got = r.first(items);
	assert got == "one";
}

test "classCalls: method with number[] param sums correctly" {
	const op = new NumOp();
	const values: number[] = [1, 2, 3, 4];
	const total = op.sum(values);
	assert total == 10;
}

test "classCalls: ctor with array param accepts array literal" {
	const c = new CtorBox([1, 2, 3]);
	assert c.count == 3;
}

test "classCalls: 3-level inheritance with super() chain" {
	const c = new C1(10, 20, 30);
	assert c.x == 10;
	assert c.y == 20;
	assert c.z == 30;
}

test "classCalls: static method with array param" {
	const items: int32[] = [1, 2, 3, 4];
	const total = StaticOps.sumAll(items);
	assert total == 10;
}

test "classCalls: cross-module class instantiation + method call" {
	const a = new CrossA(7);
	assert a.getX() == 7;
}

test "classCalls: cross-module inheritance with super() across modules" {
	const b = new CrossB(3, 4);
	assert b.sum() == 7;
}

test "classCalls: explicit type arg instantiates static of generic class" {
	const a = StaticFactoryBox.make<int32>(5);
	assert a.v == 5;
}

test "classCalls: annotated destination instantiates static of generic class" {
	const b: StaticFactoryBox<int32> = StaticFactoryBox.make(7);
	assert b.v == 7;
}

test "classCalls: per-type instantiations coexist" {
	const c = StaticFactoryBox.make<string>("hey");
	assert c.v == "hey";
	assert c.v.length == 3;
}

test "classCalls: instance method overload dispatches on param type" {
	const b = new MethodOverloadBox();
	assert b.describe(5) == "int:5";
	assert b.describe("x") == "str:x";
}

test "classCalls: instance method overload dispatches on arity" {
	const b = new MethodOverloadBox();
	assert b.add(2) == 2;
	assert b.add(2, 3) == 5;
}

test "classCalls: static method overload dispatches on param type" {
	assert MethodOverloadBox.make(5) == "static-int:5";
	assert MethodOverloadBox.make("x") == "static-str:x";
}

test "classCalls: a static and an instance method may share a name" {
	const s = new Slot();
	assert Slot.of(5) == "static:5";
	assert s.of("x") == "inst:x";
}

test "classCalls: overloaded methods may differ in return type" {
	const b = new MethodOverloadBox();
	assert b.pick(4) == 5;
	assert b.pick("x") == "s:x";
}

test "classCalls: this in a generic constructor calls the class's own method" {
	const b = new ConstructorInstanceBag<int32>([1, 2, 3]);
	assert b.items.length == 3;
	assert b.me().items.length == 3;
}

test "classCalls: this in a generic constructor is the concrete instance type" {
	const b = new ConstructorInstanceIntBag<int32>([1, 2]);
	assert b.items.length == 3;
	assert b.items[2] == 100;
}

test "classCalls: this in a two-parameter generic constructor is its instance" {
	const p = new ConstructorInstancePair<int32, string>(7, "z");
	assert p.ks.length == 2;
	assert p.vs[1] == "z";
}
