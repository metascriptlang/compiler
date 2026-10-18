// @stdout: span=a1b1 array=a1b2 kept=ab3 local=b4
// note: a string-literal discriminant of a tagged union is read off its tag, so its last read is a value and never moved out of the variant. Covered: match over a Span element, switch over an array element, the discriminant kept in a string beside a cast, and a local returned from a call.

struct A { kind: "a"; x: int32; }
struct B { kind: "b"; pts: int32[]; }
type Op = A | B;

const kept: int32[][] = [];
function keep(p: int32[]): void { kept.push(p); }

function viaSpan(ops: Span<Op>): string {
	let out = "";
	for (const op of ops) {
		match (op.kind) {
			"a" => { out = out + "a" + op.x.toString(); }
			"b" => { keep(op.pts); out = out + "b" + kept.length.toString(); }
		}
	}
	return out;
}

function viaArray(ops: Op[]): string {
	let out = "";
	for (const op of ops) {
		switch (op.kind) {
			case "a": out = out + "a" + op.x.toString(); break;
			case "b": keep(op.pts); out = out + "b" + kept.length.toString(); break;
		}
	}
	return out;
}

function keptKind(ops: Op[]): string {
	let out = "";
	for (const op of ops) {
		const k: string = op.kind;
		out = out + k;
		if (k === "b") keep((op as B).pts);
	}
	return out + kept.length.toString();
}

function make(): Op { return { kind: "b", pts: [3] }; }
function fromCall(): string {
	const o = make();
	const k: string = o.kind;
	keep((o as B).pts);
	return k;
}

const arr: Op[] = [{ kind: "a", x: 1 }, { kind: "b", pts: [1, 2] }];
const span = viaSpan(arr);
const array = viaArray(arr);
const k = keptKind(arr);
const local = fromCall() + kept.length.toString();
console.log(`span=${span} array=${array} kept=${k} local=${local}`);
