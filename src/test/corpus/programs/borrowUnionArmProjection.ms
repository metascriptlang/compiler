// @stdout: field=7 field=1 local=7 local=1 param=7 param=1 third=3
enum Kind { Scalar, Flag, Pair }
type Payload = match (kind: Kind) {
	Kind.Scalar => { value: int32 },
	Kind.Flag => { enabled: boolean },
	Kind.Pair => { left: int32, right: int32 },
};
struct Holder { payload: Payload; }

function readField(holder: Holder): int32 {
	const payload: Borrow<Payload> = holder.payload;
	match (payload.kind) {
		Kind.Scalar => { return payload.value; },
		Kind.Flag => { return payload.enabled ? 1 : 0; },
		Kind.Pair => { return payload.left + payload.right; },
	}
}
function readLocal(source: Payload): int32 {
	const payload: Borrow<Payload> = source;
	match (payload.kind) {
		Kind.Scalar => { return payload.value; },
		Kind.Flag => { return payload.enabled ? 1 : 0; },
		Kind.Pair => { return payload.left + payload.right; },
	}
}
function readParam(payload: Borrow<Payload>): int32 {
	match (payload.kind) {
		Kind.Scalar => { return payload.value; },
		Kind.Flag => { return payload.enabled ? 1 : 0; },
		Kind.Pair => { return payload.left + payload.right; },
	}
}

const scalar: Holder = { payload: { kind: Kind.Scalar, value: 7 } };
const flag: Holder = { payload: { kind: Kind.Flag, enabled: true } };
const pair: Holder = { payload: { kind: Kind.Pair, left: 1, right: 2 } };
function make(scalar: boolean): Payload { return scalar ? { kind: Kind.Scalar, value: 7 } : { kind: Kind.Flag, enabled: true }; }
const a: Payload = make(true);
const b: Payload = make(false);
console.log(`field=${readField(scalar)} field=${readField(flag)} local=${readLocal(a)} local=${readLocal(b)} param=${readParam(a)} param=${readParam(b)} third=${readField(pair)}`);
