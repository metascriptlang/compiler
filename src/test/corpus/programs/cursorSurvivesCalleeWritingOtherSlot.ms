// @stdout: cursor-slot kept=36:cfg:xxx line=3 pushed=2:4 detached=0:5 alias=34:cfg: global=35:cfg: hook=36:cfg: override=34:cfg: fnValue=34:cfg: awaited=34:cfg: struct=34:cfg:
let out = "cursor-slot";
function report(name: string, text: string): void { out += ` ${name}=${text.length}:${text.substring(0, 4)}`; }

class Doc {
	value: string;
	line: string = "l";
	kids: Doc[] = [];
	constructor(value: string) { this.value = value; }
}

function bump(o: Doc): void { o.line = o.line + "!"; }
function kept(o: Doc): string {
	const t = o.value;
	bump(o);
	return t + o.line;
}
const k = new Doc(`cfg:${"x".repeat(30)}`);
out += ` kept=${kept(k).length}:${kept(k).substring(0, 7)}`;
out += ` line=${k.line.length}`;

function mk(i: int32): Doc { return new Doc(`kid${i}`); }
function pushes(a: Doc): void {
	for (let i = 0; i < 4; i += 1) a.kids.push(mk(i));
	out += ` pushed=${a.kids.length > 1 ? 2 : 0}:${a.kids.length}`;
}
pushes(new Doc("p"));

function mkReset(a: Doc, i: int32): Doc { a.kids = []; return new Doc(`kid${i}`); }
function detaches(a: Doc): void {
	for (let i = 0; i < 5; i += 1) a.kids.push(mkReset(a, i));
	out += ` detached=${a.kids.length}:5`;
}
detaches(new Doc("d"));

function clobber(x: Doc): void { x.value = "z" + "q".repeat(40); }
function viaAlias(o: Doc): void {
	const t = o.value;
	const alias = o;
	clobber(alias);
	report("alias", t);
}
viaAlias(new Doc(`cfg:${"x".repeat(30)}`));

const shared = new Doc(`cfg:${"x".repeat(31)}`);
function clobberShared(x: Doc): void { shared.value = "z" + "q".repeat(40); }
function viaGlobal(o: Doc): void {
	const t = o.value;
	clobberShared(o);
	report("global", t);
}
viaGlobal(shared);

class Tmp { doc: Hooked; constructor(d: Hooked) { this.doc = d; } onDestroy(): void { this.doc.value = "h" + "q".repeat(40); } }
class Hooked { value: string; tmp: Tmp | null = null; constructor(value: string) { this.value = value; } }
function release(o: Hooked): void { o.tmp = null; }
function viaHook(o: Hooked): void {
	const t = o.value;
	release(o);
	report("hook", t);
}
const hooked = new Hooked(`cfg:${"x".repeat(32)}`);
hooked.tmp = new Tmp(hooked);
viaHook(hooked);

abstract class Poker { abstract poke(d: Doc): void; }
class Setter extends Poker { poke(d: Doc): void { d.value = "o" + "q".repeat(40); } }
function viaOverride(p: Poker, o: Doc): void {
	const t = o.value;
	p.poke(o);
	report("override", t);
}
viaOverride(new Setter(), new Doc(`cfg:${"x".repeat(30)}`));

function viaFnValue(f: (d: Doc) => void, o: Doc): void {
	const t = o.value;
	f(o);
	report("fnValue", t);
}
viaFnValue(clobber, new Doc(`cfg:${"x".repeat(30)}`));

async function clobberLater(o: Doc): Promise<void> {
	await Promise.resolve(0);
	o.value = "a" + "q".repeat(40);
}
async function viaAwait(o: Doc): Promise<void> {
	const t = o.value;
	await clobberLater(o);
	report("awaited", t);
}
await viaAwait(new Doc(`cfg:${"x".repeat(30)}`));

struct Named { name: string; n: int64; }
function touch(p: Named): void { out += ""; }
function viaStruct(): void {
	const p: Named = { name: `cfg:${"x".repeat(30)}`, n: 1 };
	const t = p.name;
	touch(p);
	report("struct", t);
}
viaStruct();

console.log(out);
