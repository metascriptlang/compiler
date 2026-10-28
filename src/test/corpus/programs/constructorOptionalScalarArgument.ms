// @stdout: plain=5,-1 generic=2.5,0 super=7,-1 nested=3
// @exit: 0
// note: a scalar passed to an optional constructor parameter becomes the parameter's nullable value for the call only, through `new`, a generic class and `super(...)`.

class Plain {
	n: int32;
	constructor(n?: int32) { this.n = n == null ? -1 : n; }
}

class Scaled<T> {
	k: float64;
	constructor(k?: float64, tag?: T) { this.k = k == null ? 0 : k; }
}

class Child extends Plain {
	constructor(n?: int32) { super(n == null ? null : n + 2); }
}

class Outer {
	inner: Plain;
	constructor(n?: int32) { this.inner = new Plain(n); }
}

console.log(`plain=${new Plain(5).n},${new Plain().n} generic=${new Scaled<string>(2.5, "t").k},${new Scaled<string>().k} super=${new Child(5).n},${new Child().n} nested=${new Outer(3).inner.n}`);
