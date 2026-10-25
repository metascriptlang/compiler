// @stdout: sink-cursor-copies a a a a a b true
// A cursor that reaches a sink formal is copied there: the source keeps its value after the call,
// and replacing the source frees only its own reference.
let line = "sink-cursor-copies";
function report(text: string): void { line += ` ${text}`; }

class Box {
	v: string;
	constructor(v: string) { this.v = v; }
}

class Holder {
	child: Box;
	constructor(s: string) { this.child = new Box(s); }
}

function keep(sink b: Box, out: Box[]): void {
	out.push(b);
}

function viaPush(h: Holder, out: Box[]): void {
	const c = h.child;
	out.push(c);
	report(c.v);
}

function viaSinkParam(h: Holder, out: Box[]): void {
	const c = h.child;
	keep(c, out);
	report(c.v);
}

const h = new Holder("a");
const out: Box[] = [];
viaPush(h, out);
viaSinkParam(h, out);
report(h.child.v);
h.child = new Box("b");
report(out[0].v);
report(out[1].v);
report(h.child.v);
report(`${out[0] == out[1]}`);
console.log(line);
