// Parity program — an exported alias of `Class | null` is the nullable pointer itself. It got
// the tagged-union lifecycle hooks of a named union, whose bodies read a variant slot the
// pointer does not have, so the C compile failed.
//
// @stdout: 4 -1 9
// @stdout: 2 -1
// @exit: 0

class FlowList {
	flow: int32;
	next: MaybeFlow = null;
	constructor(flow: int32) { this.flow = flow; }
}
export type MaybeFlow = FlowList | null;
export type MaybeSpan = { lo: int32, hi: int32 } | null;

function head(l: MaybeFlow): int32 { return l == null ? -1 : l.flow; }
function span(s: MaybeSpan): int32 { return s == null ? -1 : s.hi - s.lo; }

const a: MaybeFlow = new FlowList(4);
const b: MaybeFlow = null;
const c = new FlowList(1);
c.next = new FlowList(9);
console.log(head(a), head(b), head(c.next));
const s: MaybeSpan = { lo: 1, hi: 3 };
console.log(span(s), span(null));
