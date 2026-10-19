// @stdout: 7|empty|3|empty|9|empty|5
// @exit: 0
// note: an object literal of a discriminated union written into a `Value | null` slot builds a Value that is then wrapped into the Maybe, as a plain struct literal is. It used to be stamped with the Maybe type, so no wrap was inserted and the C build wrote the payload fields into the Maybe struct.

enum Kind { A, B }
type Value = match (kind: Kind) {
	Kind.A => { x: int32 },
	Kind.B => {},
};
struct Box { value: Value | null; }
interface IBox { value: Value | null; }

function show(v: Value | null): string {
	if (v === null) return "null";
	if (v.kind == Kind.A) return String(v.x);
	return "empty";
}

const local: Value | null = { kind: Kind.A, x: 7 };
const empty: Value | null = { kind: Kind.B };
const box: Box = { value: { kind: Kind.B } };
const ibox: IBox = { value: { kind: Kind.A, x: 5 } };
const out: string[] = [];
out.push(show(local));
out.push(show(empty));
out.push(show({ kind: Kind.A, x: 3 }));
out.push(show(box.value));
let later: Box = { value: null };
later.value = { kind: Kind.A, x: 9 };
out.push(show(later.value));
out.push(show({ kind: Kind.B }));
out.push(show(ibox.value));
console.log(out.join("|"));
