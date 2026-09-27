// @stdout: instance-scope clamp=10 loop=10 lambda=10 nested=4 made=7
// note: a generic instance body names its own module's `limit` and `Box`, while each caller declares a local of the same name (same type, in a loop, as a lambda parameter, as a local named like the type) and an outer generic's type parameter is named `Box`. The body reads the module bindings on every lane; C used to fail "use of undeclared identifier" and JS threw ReferenceError.
const limit: int32 = 10;

struct Box { n: int32; }

function clamp<T>(v: T, n: int32): int32 { return n > limit ? limit : n; }

function inner<U>(u: U): int32 {
	const b: Box = { n: 4 };
	return b.n;
}

function outer<Box>(x: Box): int32 { return inner(x); }

function made<T>(v: T): Box {
	const b: Box = { n: 7 };
	return b;
}

function sameType(): int32 {
	const limit: int32 = 99;
	return clamp(1, 42);
}

function inLoop(): int32 {
	let got = 0;
	for (const limit of [5]) {
		got = clamp("s", 42);
	}
	return got;
}

function viaLambda(): int32 {
	const f = (limit: int32): int32 => clamp(true, 42);
	return f(3);
}

function localNamedLikeType(): int32 {
	const Box = 3;
	return made(2.5).n;
}

console.log(`instance-scope clamp=${sameType()} loop=${inLoop()} lambda=${viaLambda()} nested=${outer("s")} made=${localNamedLikeType()}`);
