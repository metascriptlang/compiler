// @stdout: 144 144 300 1 1 3 7 abc
// note: an unannotated `@comptime { }` block takes the static type of what its body returns, as an annotated one does: the struct, a struct holding it, a sized array of it, a narrow scalar. `untyped.bytes[7] + untyped.bytes[7]` is uint8 arithmetic like the annotated binding's. Same output on every lane.
struct Tag { bytes: uint8[8]; }
struct Outer { tag: Tag; level: uint16; }
struct Box<T> { v: T; }
function make(): Tag { return { bytes: [1, 2, 3, 4, 5, 6, 7, 200] }; }
function main(): void {
	const untyped = @comptime { return make(); };
	const typed: Tag = @comptime { return make(); };
	const outer = @comptime { return { tag: make(), level: 300 } as Outer; };
	const pair = @comptime { const t = make(); const two: Tag[2] = [t, t]; return two; };
	const small = @comptime { return 5 as uint8; };
	const list = @comptime { return [1, 2, 3]; };
	const boxed = @comptime { const b: Box<int32> = { v: 7 }; return b; };
	const text = @comptime { return "ab" + "c"; };
	console.log(`${untyped.bytes[7] + untyped.bytes[7]} ${typed.bytes[7] + typed.bytes[7]} ${outer.level} ${pair[1].bytes[0]} ${sizeof(small)} ${list.length} ${boxed.v} ${text}`);
}
main();
