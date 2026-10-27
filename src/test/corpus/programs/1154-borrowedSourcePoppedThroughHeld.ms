// @stdout: borrowed-source-held global=28:cfg: free=28:cfg: virt=28:cfg: deep=28:cfg: boxed=28:cfg:
let out = "borrowed-source-held";
function report(name: string, text: string): void { out += ` ${name}=${text.length}:${text.substring(0, 4)}`; }
function fresh(): string { return `cfg:${"x".repeat(24)}`; }

class Box { v: string; constructor(v: string) { this.v = v; } }

let g: string[] = [];
function keep(k: string[]): void { g = k; }
function popG(): void { g.pop(); }
function viaGlobal(k: string[], s: string): void { keep(k); popG(); report("global", s); }

class Holder { k: string[]; constructor(k: string[]) { this.k = k; } }
function popH(h: Holder): void { h.k.pop(); }
function viaFree(k: string[], s: string): void { const h = new Holder(k); popH(h); report("free", s); }

class Base { w(k: string[]): void {} }
class Sub extends Base { w(k: string[]): void { k.pop(); } }
function pick(): Base { return new Sub(); }
function virt(k: string[], s: string): void { pick().w(k); report("virt", s); }

function inner(h: Holder): void { popH(h); }
function middle(h: Holder): void { inner(h); }
function deep(k: string[], s: string): void { middle(new Holder(k)); report("deep", s); }

let gb: Box[] = [];
function keepBoxes(k: Box[]): void { gb = k; }
function boxed(k: Box[], b: Box): void { keepBoxes(k); gb.pop(); report("boxed", b.v); }

function main(): void {
	const a: string[] = [fresh()];
	viaGlobal(a, a[0]);
	const b: string[] = [fresh()];
	viaFree(b, b[0]);
	const c: string[] = [fresh()];
	virt(c, c[0]);
	const d: string[] = [fresh()];
	deep(d, d[0]);
	const e: Box[] = [new Box(fresh())];
	boxed(e, e[0]);
	console.log(out);
}
main();
