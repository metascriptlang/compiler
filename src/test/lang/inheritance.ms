// Language tests: type inheritance / field merging.
//
// Covers Bug 1 deferred (object intersection in type aliases), Bug 4 (interface
// multi-extend), and class inheritance with super. struct/struct-intersection
// forms are exercised via native-compile probes (`/tmp/ms-bug2/p2-*.ms`) since
// the bun-hosted JS test runner doesn't transpile `struct extends` / `struct = T`.
//
// Two-tier representation:
//   - interface/struct/type alias: flatten parent fields into typeChildren
//   - class: same flatten + keep typeExtra (used by static field chain) +
//     HasInheritedFields flag suppresses DRC parent destroy genCall (avoid double-free)
//
// If any of these fail in the future, the inheritance gap re-opened.

interface IUser { id: number; name: string; }
interface Timestamped { createdAt: number; }

// ===== Interface single + multi extend =====

test "interface single extends inherits parent field" {
	interface Admin extends IUser { role: string; }
	const a: Admin = { id: 1, name: "alice", role: "admin" };
	assert a.id === 1;
	assert a.name === "alice";
	assert a.role === "admin";
}

test "interface multi-extend merges fields from all parents" {
	interface Audited extends IUser, Timestamped { byUser: string; }
	const a: Audited = { id: 7, name: "bob", createdAt: 100, byUser: "system" };
	assert a.id === 7;
	assert a.createdAt === 100;
	assert a.byUser === "system";
}

test "nested inheritance C extends B extends A" {
	interface AA1 { x: number; }
	interface BB1 extends AA1 { y: number; }
	interface CC1 extends BB1 { z: number; }
	const c: CC1 = { x: 1, y: 2, z: 3 };
	assert c.x === 1;
	assert c.y === 2;
	assert c.z === 3;
}

// ===== Type alias intersection (Bug 1 deferred close-out) =====

test "type alias intersection of objects merges fields" {
	type Extended = IUser & { role: string };
	const e: Extended = { id: 1, name: "alice", role: "user" };
	assert e.id === 1;
	assert e.role === "user";
}

test "type alias intersection of two anonymous objects" {
	type AB = { a: number } & { b: string };
	const ab: AB = { a: 42, b: "hi" };
	assert ab.a === 42;
	assert ab.b === "hi";
}

// ===== Branded primitives still work (Bug 1 erasure preserved) =====

test "branded primitive intersection erases to primitive" {
	type CubeId = string & { __brand: "CubeId" };
	const id: CubeId = "abc-123" as CubeId;
	assert (id as string) === "abc-123";
}

// ===== Class field inheritance =====

class BaseAnimal { legs: number = 4; }
class Mammal extends BaseAnimal { warmBlooded: boolean = true; }

test "class extends inherits parent properties" {
	const m = new Mammal();
	m.legs = 4;
	m.warmBlooded = true;
	assert m.legs === 4;
	assert m.warmBlooded;
}

test "class 3-level extends" {
	class L1 { a: number = 0; }
	class L2 extends L1 { b: number = 0; }
	class L3 extends L2 { c: number = 0; }
	const l = new L3();
	l.a = 1; l.b = 2; l.c = 3;
	assert l.a === 1;
	assert l.b === 2;
	assert l.c === 3;
}

// ===== Class super() + constructor inheritance =====

test "class super(args) chains to parent constructor" {
	class P {
		x: number;
		constructor(x: number) { this.x = x; }
	}
	class C extends P {
		y: number;
		constructor(x: number, y: number) {
			super(x);
			this.y = y;
		}
	}
	const c = new C(10, 20);
	assert c.x === 10;
	assert c.y === 20;
}

test "class super() with no args" {
	class P0 {
		x: number;
		constructor() { this.x = 99; }
	}
	class C0 extends P0 {
		y: number;
		constructor(y: number) {
			super();
			this.y = y;
		}
	}
	const c = new C0(5);
	assert c.x === 99;
	assert c.y === 5;
}

// ===== Generic inheritance (Phase 7) =====

test "interface generic inheritance with substitution" {
	interface Container<T> { value: T; }
	interface Box<T> extends Container<T> { tag: string; }
	const b: Box<number> = { value: 42, tag: "n" };
	assert b.value === 42;
	assert b.tag === "n";
}

test "interface concrete instantiation of generic parent" {
	interface Holder<T> { item: T; }
	interface IntHolder extends Holder<int32> { extra: string; }
	const h: IntHolder = { item: 7 as int32, extra: "x" };
	assert h.item === 7;
	assert h.extra === "x";
}
