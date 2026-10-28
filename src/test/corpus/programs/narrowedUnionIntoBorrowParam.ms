// @stdout: borrow=7 ref=8 val=7 flagged=2 field=3 refTwice=8 viaIf=11
enum Kind { Scalar, Pair }
type Payload = match (kind: Kind) {
	Kind.Scalar => { value: int32 },
	Kind.Pair => { left: int32, right: int32 },
};
struct Holder { payload: Payload; }

function readBorrow(p: Borrow<Payload>): int32 {
	match (p.kind) {
		Kind.Scalar => { return p.value; },
		Kind.Pair => { return p.left + p.right; },
	}
}
function bump(ref p: Payload): void {
	p = { kind: Kind.Scalar, value: 8 };
}
function readValue(p: Payload): int32 {
	match (p.kind) {
		Kind.Scalar => { return p.value; },
		Kind.Pair => { return p.left + p.right; },
	}
}
function make(scalar: boolean): Payload { return scalar ? { kind: Kind.Scalar, value: 7 } : { kind: Kind.Pair, left: 1, right: 1 }; }

const a: Payload = { kind: Kind.Scalar, value: 7 };
let r: Payload = { kind: Kind.Scalar, value: 7 };
bump(r);
let twice: Payload = { kind: Kind.Scalar, value: 7 };
bump(twice);
const holder: Holder = { payload: { kind: Kind.Pair, left: 1, right: 2 } };
const viaCall: Payload = make(true);
let viaIf: Payload = make(true);
let viaIfOut = 0;
if (viaIf.kind == Kind.Scalar) {
	viaIfOut = readBorrow(viaIf) + 4;
}
const pairLocal: Payload = { kind: Kind.Pair, left: 1, right: 1 };
console.log(`borrow=${readBorrow(a)} ref=${(r.kind == Kind.Scalar) ? r.value : 0} val=${readValue(a)} flagged=${readBorrow(pairLocal)} field=${readBorrow(holder.payload)} refTwice=${(twice.kind == Kind.Scalar) ? twice.value : 0} viaIf=${viaIfOut}`);
