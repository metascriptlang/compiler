// note: same-named methods on one class are distinct routines and must keep
// distinct emitted names — by param type, by arity, and for statics. Was: both
// bodies mangled to one C name (conflicting types at cc) and on js the later
// class member clobbered the earlier one, so every call ran the last body.
// Guard: fixedbugs/bug129.
class Box {
	v: int32 = 0;
	describe(n: int32): string { return "int:" + n.toString(); }
	describe(s: string): string { return "str:" + s; }
	add(a: int32): int32 { return a; }
	add(a: int32, b: int32): int32 { return a + b; }
	static make(n: int32): string { return "static-int:" + n.toString(); }
	static make(s: string): string { return "static-str:" + s; }
}

class Slot {
	static of(n: int32): string { return "static:" + n.toString(); }
	of(s: string): string { return "inst:" + s; }
}

function main(): void {
	const b = new Box();
	console.log("type=" + b.describe(5) + "|" + b.describe("x"));
	console.log("arity=" + b.add(2).toString() + "|" + b.add(2, 3).toString());
	console.log("static=" + Box.make(5) + "|" + Box.make("x"));
	const s = new Slot();
	console.log("share=" + Slot.of(5) + "|" + s.of("x"));
}
main();
