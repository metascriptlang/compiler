// @skip-js: C and the Raiser own the copies through destroy hooks the DRC runs; JS has no destructors
// @stdout: bc=g2 hl=g3 loop=2 call=g2 nested=xg2 made=22 destroyed=22
let made = 0;
let destroyed = 0;

class D {
	t: string;
	constructor(t: string) { this.t = t; made += 1; }
	onDestroy() { destroyed += 1; }
}
interface Holder { l: D[]; }

function txt(s: string): D { return new D(s); }
function grp(xs: D[]): D { return new D("g" + xs.length.toString()); }
function pair(a: D, b: D): D { return new D(a.t + b.t); }
function list(): D[] { return [txt("f")]; }

function viaIndex(bc: D[][]): D { return grp([...bc[0], txt(",")]); }
function viaMember(a: D, h: Holder): D { return grp([a, ...h.l, txt(",")]); }
function viaLoop(items: D[], bc: D[][]): number {
	const out: D[] = [];
	for (let i = 0; i < items.length; i += 1) out.push(grp([items[i], ...bc[i], txt(",")]));
	return out.length;
}
function viaCall(): D { return grp([...list(), txt(",")]); }
function viaNested(bc: D[][]): D { return pair(txt("x"), grp([...bc[0], txt(",")])); }

function run(): string {
	const bc: D[][] = [[txt("c")]];
	const h: Holder = { l: [txt("d")] };
	const items: D[] = [txt("a"), txt("b")];
	const wide: D[][] = [[txt("e")], [txt("f")]];
	return "bc=" + viaIndex(bc).t + " hl=" + viaMember(txt("a"), h).t + " loop=" + viaLoop(items, wide).toString()
		+ " call=" + viaCall().t + " nested=" + viaNested(bc).t;
}
const line = run();
console.log(line + " made=" + made.toString() + " destroyed=" + destroyed.toString());
