// @stdout: direct 1 2 nested 1 2 sized 9 16 plain 5 5
// @exit: 0

struct A { x: int32; }
struct B { y: int32; }

function tag(this typeof A): uint64 { return 1; }
function tag(this typeof B): uint64 { return 2; }

function tagOf<T>(): uint64 {
	return @comptime { return T.tag(); };
}

function viaOuter<U>(): uint64 {
	return tagOf<U>();
}

function widthOf<T>(): uint64 {
	return @comptime { return T.tag() * 7 + 2; };
}

function five<T>(value: T): uint64 {
	return @comptime { return 5; };
}

const a: A = { x: 1 };
console.log(`direct ${tagOf<A>()} ${tagOf<B>()} nested ${viaOuter<A>()} ${viaOuter<B>()} sized ${widthOf<A>()} ${widthOf<B>()} plain ${five<int32>(3)} ${five<A>(a)}`);
