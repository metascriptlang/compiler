// @stdout: caught first|caught second|caught third|base a|base b|let first|let second|bound first|param second|returned first|field second|array first|rethrown plain|ok
// note: a reference narrowed by `x instanceof A || x instanceof B` is still the one pointer its declaration holds;
// a field or method read on it goes through that pointer, not through a tagged-union carrier.
class First extends Error {}
class Second extends Error {}
class Third extends Error {}

class Holder { v: First | Second | null = null; }
function readParam(v: First | Second): string { return v.message; }
function pick(e: Error): First | Second {
	if (e instanceof First || e instanceof Second) return e;
	throw e;
}

class Base {
	label: string = "";
}
class A extends Base { constructor() { super(); this.label = "a"; } }
class B extends Base { constructor() { super(); this.label = "b"; } }
class C extends Base { constructor() { super(); this.label = "c"; } }

function fails(which: int32): void {
	if (which == 1) { throw new First("first"); }
	if (which == 2) { throw new Second("second"); }
	if (which == 3) { throw new Third("third"); }
	throw new Error("plain");
}

function plain(): Error { return new Error("plain"); }

const out: string[] = [];

for (const which of [1, 2, 3] as int32[]) {
	try {
		fails(which);
	} catch (e) {
		if (e instanceof First || e instanceof Second || e instanceof Third) {
			out.push(`caught ${e.message}`);
		}
	}
}

for (const which of [1, 2] as int32[]) {
	const b: Base = which == 1 ? new A() : new B();
	if (b instanceof A || b instanceof B) {
		out.push(`base ${b.label}`);
	}
}

const asError: Error[] = [new First("first"), new Second("second")];
for (const e of asError) {
	if (e instanceof First || e instanceof Second) out.push(`let ${e.message}`);
}

const holder = new Holder();
const stored: (First | Second)[] = [];
const e1: Error = asError[0];
const e2: Error = asError[1];
if (e1 instanceof First || e1 instanceof Second) {
	const x = e1;
	out.push(`bound ${x.message}`);
}
if (e2 instanceof First || e2 instanceof Second) out.push(`param ${readParam(e2)}`);
out.push(`returned ${pick(e1).message}`);
if (e2 instanceof First || e2 instanceof Second) {
	holder.v = e2;
	stored.push(e1 instanceof First || e1 instanceof Second ? e1 : e2);
}
out.push(`field ${holder.v!.message}`);
out.push(`array ${stored[0].message}`);

try {
	try {
		fails(4);
	} catch (e) {
		if (e instanceof First || e instanceof Second) {
			out.push("wrong");
		} else {
			throw e;
		}
	}
} catch (e) {
	if (e instanceof Error) out.push(`rethrown ${e.message}`);
}

const e0: Error = plain();
if (e0 instanceof First || e0 instanceof Second) out.push("wrong");
else out.push("ok");

console.log(out.join("|"));
