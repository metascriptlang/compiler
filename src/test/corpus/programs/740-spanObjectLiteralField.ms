// @stdout: span-object-literal-field 3 1 3 3 2 7 3 3

struct Packet { view: Span<uint8>; tag: int32; }
interface Frame { view: Span<uint8>; n: int32; }

function firstByte(s: Span<uint8>): uint8 {
	return s[0];
}

const dyn: uint8[] = [1, 2, 3];
const fixed: uint8[3] = [3, 4, 5];
const vec: Vec<uint8> = [7, 8];

const p1: Packet = { view: dyn, tag: 0 };
const p2: Packet = { view: fixed, tag: 0 };
const p3: Packet = { view: vec, tag: 0 };
const f1: Frame = { view: dyn, n: 0 };

let p4: Packet = { view: dyn, tag: 1 };
p4.view = fixed;

console.log("span-object-literal-field",
	p1.view.length, firstByte(p1.view),
	p2.view.length, p2.view[0],
	p3.view.length, p3.view[0],
	f1.view.length, p4.view.length);
