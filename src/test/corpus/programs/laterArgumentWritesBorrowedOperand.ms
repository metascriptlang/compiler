// @stdout: global one:a:10 | global two:ab:10 | field one:fa:10 | field two:fab:10 | element one:ea:10 | element two:eab:10 | closure one:ca:7 | closure two:cab:7 | new one:na:9 | new two:nab:9
let gs = "a";
let gc = "ca";
let gn = "na";

class Holder { name: string = "fa"; }
class Bumper {
	n: int32 = 9;
	constructor() { gn = gn + "b"; }
}

const h = new Holder();
const names: string[] = ["ea"];
const out: string[] = [];

function bumpGlobal(): int32 { gs = gs + "b"; return 10; }
function bumpField(): int32 { h.name = h.name + "b"; return 10; }
function bumpElement(): int32 { names[0] = names[0] + "b"; return 10; }
const bumpClosure = (): int32 => { gc = gc + "b"; return 7; };

function record(kind: string, tag: string, a: string, n: int32): int32 {
	out.push(kind + " " + tag + ":" + a + ":" + n);
	return n;
}

record("global", "one", gs, bumpGlobal());
record("global", "two", gs, bumpGlobal());
record("field", "one", h.name, bumpField());
record("field", "two", h.name, bumpField());
record("element", "one", names[0], bumpElement());
record("element", "two", names[0], bumpElement());
record("closure", "one", gc, bumpClosure());
record("closure", "two", gc, bumpClosure());
record("new", "one", gn, new Bumper().n);
record("new", "two", gn, new Bumper().n);
console.log(out.join(" | "));
