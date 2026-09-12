// GUARD-JS
// The readonly rule outside the declaring constructor, TypeScript-style: a
// method, an arrow inside the constructor, a free function, a static field,
// and a subclass constructor or any access writing a field the parent declares
// are all diagnostics. The exemption is `this.x` in the constructor of the
// declaring class only.
//
// GUARD-CHECK-FAIL cannot assign to 'inMethod' because it is a read-only property
// GUARD-CHECK-FAIL cannot assign to 'inArrow' because it is a read-only property
// GUARD-CHECK-FAIL cannot assign to 'inFree' because it is a read-only property
// GUARD-CHECK-FAIL cannot assign to 'inStatic' because it is a read-only property
// GUARD-CHECK-FAIL cannot assign to 'inSubCtor' because it is a read-only property
// GUARD-CHECK-FAIL cannot assign to 'inherited' because it is a read-only property

class K {
	readonly inMethod: int32 = 1;
	readonly inArrow: int32 = 2;
	readonly inFree: int32 = 3;
	readonly inSubCtor: int32 = 4;
	readonly inherited: int32 = 5;
	static readonly inStatic: int32 = 6;
	constructor() {
		const f = (): void => { this.inArrow = 20; };
		f();
	}
	bump(): void { this.inMethod = 10; }
}

class Sub extends K {
	constructor() {
		super();
		this.inSubCtor = 40;
	}
}

function free(k: K): void { k.inFree = 30; }
function viaSub(s: Sub): void { s.inherited = 50; }

K.inStatic = 60;
free(new K());
viaSub(new Sub());
console.log("unreachable");
