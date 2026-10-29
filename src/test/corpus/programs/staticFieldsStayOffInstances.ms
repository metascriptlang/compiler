// @stdout: name=author count=3 value=9 child=4,author,7 shared=5
// note: a static field lives once on its class, not in each instance, so constructing an instance of a class with static fields, or of a subclass, lays only its instance fields.

class Base {
	static name: string = "author";
	static count: int32 = 3;
	value: int32;
	constructor(value: int32) { this.value = value; }
}

class Child extends Base {
	static extra: int32 = 7;
	more: int32 = 4;
	constructor() { super(1); }
}

class Shared {
	static total: int32 = 0;
	n: int32;
	constructor(n: int32) { this.n = n; Shared.total += n; }
}

const b = new Base(9);
const c = new Child();
new Shared(2);
new Shared(3);
console.log(`name=${Base.name} count=${Base.count} value=${b.value} child=${c.more},${Base.name},${Child.extra} shared=${Shared.total}`);
