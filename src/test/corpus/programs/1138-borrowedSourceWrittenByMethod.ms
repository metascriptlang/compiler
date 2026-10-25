// @stdout: borrowed-source-method param=28:cfg: field=28:cfg: static=28:cfg: setter=28:cfg: override=28:cfg: hook=28:cfg:
let out = "borrowed-source-method";
function report(name: string, text: string): void { out += ` ${name}=${text.length}:${text.substring(0, 4)}`; }
function fresh(): string { return `cfg:${"x".repeat(24)}`; }

class Box { v: string; constructor(v: string) { this.v = v; } }

class Shifter { run(k: string[]): void { k.shift(); } }
function param(k: string[], s: string): void { new Shifter().run(k); report("param", s); }

class Popper { k: string[]; constructor(k: string[]) { this.k = k; } run(): void { this.k.pop(); } }
function field(k: string[], s: string): void { new Popper(k).run(); report("field", s); }

class Statics { static run(k: string[]): void { k.shift(); } }
function viaStatic(k: string[], s: string): void { Statics.run(k); report("static", s); }

class Poker { k: string[]; constructor(k: string[]) { this.k = k; } set poke(v: int32) { this.k.pop(); } get poke(): int32 { return 0; } }
function setter(k: string[], s: string): void { const p = new Poker(k); p.poke = 1; report("setter", s); }

class Base { w(k: Box[]): void {} }
class Sub extends Base { w(k: Box[]): void { k.pop(); } }
function pick(): Base { return new Sub(); }
function override(k: Box[], b: Box): void { pick().w(k); report("override", b.v); }

class Guard { k: Box[]; constructor(k: Box[]) { this.k = k; } onDestroy(): void { this.k.pop(); } }
let holder: Guard | null = null;
function hook(k: Box[], b: Box): void { holder = null; report("hook", b.v); }

function main(): void {
	const a: string[] = [fresh()];
	param(a, a[0]);
	const b: string[] = [fresh()];
	field(b, b[0]);
	const c: string[] = [fresh()];
	viaStatic(c, c[0]);
	const d: string[] = [fresh()];
	setter(d, d[0]);
	const e: Box[] = [new Box(fresh())];
	override(e, e[0]);
	const f: Box[] = [new Box(fresh())];
	holder = new Guard(f);
	hook(f, f[0]);
	console.log(out);
}
main();
