// @stdout: 41 s41 42 41 h42 142 42 r3
// note: a call checked before its callee's body reads the return type that body infers: a function one call deeper, a function read as a value, a call at top level, a method through `this` and through a parameter, a static method, an extension, a generic class's method, and a call that discards the result of a routine still being checked. Same output on C, JS and the Raiser.
const early = top();

function a() { return b() + 1; }
function b() { const read = c; return read() * 2; }
function c() { return 20; }
function top() { return "s" + String(a()); }

class Base {
	h() { return "h" + String(new K().first()); }
}

class K {
	first() { return this.second() + 1; }
	second() { return this.third() * 2; }
	third() { return K.base() + half(); }
	static base() { return 20; }
}

function half() { return 0.5; }
function viaParam(k: K) { return k.second(); }
function viaExt(k: K) { return k.bumped() + 1; }
function bumped(this k: K) { return k.second() + 100; }

class Box<T> {
	v: T;
	constructor(v: T) { this.v = v; }
	size() { return this.count() + 1; }
	count() { return 41; }
}

let renders = 0;
function render() { renders += 1; if (renders < 3) update(); return "r" + String(renders); }
function update() { render(); }

console.log(`${a()} ${early} ${new K().first()} ${viaParam(new K())} ${new Base().h()} ${viaExt(new K())} ${new Box<string>("x").size()} ${render()}`);
