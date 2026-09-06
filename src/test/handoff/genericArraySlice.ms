// genericArraySlice — `.slice` exists for EVERY element type, not just number/string.
//
// The C-backend array prelude (std/core/array/index.cms) hand-specialized the full
// method surface for number[] and string[] but gave the generic T[] block only
// push/pop/at/setLength/capacity/splice — so `.slice` was missing for closures,
// unknown, interfaces, classes, booleans and nested arrays (neon core/array +
// render/flow, and std's own websocket/frame.ms sliceBytes workaround). The JS
// prelude (index.jms) had always declared the whole surface generically.
// Fix: a generic MS-bodied slice<T>, monomorphized per T like Nim's system slice
// (a generic proc that copies element-wise), beside the existing sortBy<T>.

interface GsVN {
	tag: string;
}

class GsBox {
	v: number;
	constructor(v: number) { this.v = v; }
}

test "slice on a closure array" {
	let fns: (() => number)[] = [];
	fns.push(() => 1);
	fns.push(() => 2);
	fns.push(() => 3);
	const head = fns.slice(0, 2);
	assert head.length == 2, "len";
	assert head[0]() == 1, "first";
	assert head[1]() == 2, "second";
}

test "slice on an interface array copies element references" {
	let vs: GsVN[] = [];
	vs.push({ tag: "a" });
	vs.push({ tag: "b" });
	const tail = vs.slice(1, 2);
	assert tail.length == 1, "len";
	assert tail[0].tag == "b", "elem";
	assert vs.length == 2, "source untouched";
	assert vs[1].tag == "b", "source elem alive";
}

test "slice on a class array" {
	let bs: GsBox[] = [];
	bs.push(new GsBox(7));
	bs.push(new GsBox(8));
	const one = bs.slice(0, 1);
	assert one.length == 1, "len";
	assert one[0].v == 7, "elem";
}

test "slice on unknown, boolean and nested arrays" {
	let us: unknown[] = [];
	us.push(1 as unknown);
	us.push(2 as unknown);
	assert us.slice(0, 1).length == 1, "unknown";

	let bs: boolean[] = [];
	bs.push(true);
	bs.push(false);
	assert bs.slice(1, 2).length == 1, "boolean";

	let ns: number[][] = [];
	ns.push([1, 2]);
	ns.push([3]);
	assert ns.slice(0, 1).length == 1, "nested";
}

test "slice clamps out-of-range bounds" {
	let fns: (() => number)[] = [];
	fns.push(() => 1);
	assert fns.slice(0, 99).length == 1, "end past the tail";
	assert fns.slice(5, 9).length == 0, "start past the tail";
	assert fns.slice(1, 0).length == 0, "reversed range";
}

test "specialized number and string slices still resolve" {
	const ns: number[] = [1, 2, 3];
	const ss: string[] = ["a", "b", "c"];
	assert ns.slice(1, 3).length == 2, "number";
	assert ns.slice(1, 3)[0] == 2, "number elem";
	assert ss.slice(0, 2).length == 2, "string";
	assert ss.slice(0, 2)[1] == "b", "string elem";
}
