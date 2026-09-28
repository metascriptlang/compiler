// @stdout: upcast init=n1 assign=l1 arg=7/9 ret=7 field=7 elem=9 call=7 nullable=7 push=changed pick=derived/base
// note: a struct value reaches a slot of its declared parent struct as a copy of the parent part, at every slot (declaration, assignment, argument two levels up, return, field, element, call result, nullable slot, push); the copy owns its strings and changes apart from its source, and overloads pick the most derived parameter. Same output on every backend.

struct Base { name: string; code: int32; }
struct Derived extends Base { tag: string; }
struct Leaf extends Derived { y: int32; }
struct Holder { b: Base; }

function make(): Derived { return { name: "m" + "1", code: 7, tag: "t" }; }
function codeOf(b: Base): int32 { return b.code; }
function up(d: Derived): Base { return d; }
function keep(bs: Base[], d: Derived): void { bs.push(d); }
function pick(b: Base): string { return "base"; }
function pick(d: Derived): string { return "derived"; }

let d: Derived = { name: "n" + "1", code: 7, tag: "t" + "1" };
const l: Leaf = { name: "l" + "1", code: 9, tag: "t" + "2", y: 3 };
const init: Base = d;
let assigned: Base = { name: "x", code: 0 };
assigned = l;
const h: Holder = { b: d };
const bs: Base[] = [d, l];
const fromCall: Base = make();
const nullable: Base | null = d;
const pushed: Base[] = [];
d.name = "changed";
keep(pushed, d);
d.name = "again";

console.log("upcast init=" + init.name + " assign=" + assigned.name
	+ " arg=" + codeOf(d).toString() + "/" + codeOf(l).toString() + " ret=" + up(d).code.toString()
	+ " field=" + h.b.code.toString() + " elem=" + bs[1].code.toString() + " call=" + fromCall.code.toString()
	+ " nullable=" + nullable!.code.toString() + " push=" + pushed[0].name + " pick=" + pick(d) + "/" + pick(init));
