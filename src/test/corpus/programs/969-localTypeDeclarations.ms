// @stdout: local-types 8 12 4 6
function f(): int32 {
	type N = int32;
	interface P { x: int32; }
	enum L { A = 3, B }
	const p: P = { x: 4 };
	const n: N = p.x;
	return n + (L.B as int32);
}

function g(k: int32): int32 {
	if (k > 0) {
		enum Scale { One = 1, Many = 3 }
		type Pair = { a: int32; b: int32 };
		const q: Pair = { a: k, b: Scale.Many as int32 };
		return q.a * q.b;
	}
	return 0;
}

function h(): int32 {
	struct Q { y: int32 }
	const q: Q = { y: 4 };
	return q.y;
}

function m(): int32 {
	class C { n: int32 = 3; twice(): int32 { return this.n * 2; } }
	return new C().twice();
}

console.log(`local-types ${f()} ${g(4)} ${h()} ${m()}`);
