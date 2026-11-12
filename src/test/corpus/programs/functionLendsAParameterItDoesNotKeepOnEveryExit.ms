// @stdout: a b c d e f g h i kept
// note: a function takes a parameter only when its body keeps it on every exit. A local handed to a call for the last time and still reachable through an Unowned edge lives to the end of the caller's scope when the callee returns early, stores in a loop that runs zero times, throws before the store (a throw statement, a call, a getter), stores inside a try, or stores under a short-circuit; the path that does store keeps the value.
class P { name: string; constructor(name: string) { this.name = name; } }
class H { up: Unowned<P> | null = null; own: P | null = null; all: P[] = []; }
class G { get v(): int32 { throw new Error("g"); } }
function boom(on: boolean): void { if (on) throw new Error("x"); }

function earlyReturn(h: H, p: P, skip: boolean): void { if (skip) return; h.own = p; }
function forZero(h: H, p: P, n: int32): void { for (let i = 0; i < n; i++) h.all.push(p); }
function whileZero(h: H, p: P, n: int32): void { let i = 0; while (i < n) { h.own = p; i++; } }
function forOfEmpty(h: H, p: P, xs: int32[]): void { for (const x of xs) h.own = p; }
function callThrows(h: H, p: P, on: boolean): void { boom(on); h.own = p; }
function throwStatement(h: H, p: P, on: boolean): void { if (on) throw new Error("x"); h.own = p; }
function getterThrows(h: H, p: P, g: G): void { const n = g.v; h.own = p; }
function storeInTry(h: H, p: P, on: boolean): void { try { boom(on); h.own = p; } catch (e) {} }
function keep(h: H, p: P): boolean { h.own = p; return true; }
function shortCircuit(h: H, p: P, on: boolean): void { const r = on && keep(h, p); }

function viaEarlyReturn(): string {
	const h = new H();
	const p = new P("a");
	h.up = p;
	earlyReturn(h, p, true);
	return h.up!.name;
}

function viaForZero(): string {
	const h = new H();
	const p = new P("b");
	h.up = p;
	forZero(h, p, 0);
	return h.up!.name;
}

function viaWhileZero(): string {
	const h = new H();
	const p = new P("c");
	h.up = p;
	whileZero(h, p, 0);
	return h.up!.name;
}

function viaForOfEmpty(): string {
	const h = new H();
	const p = new P("d");
	h.up = p;
	forOfEmpty(h, p, []);
	return h.up!.name;
}

function viaCallThrows(): string {
	const h = new H();
	const p = new P("e");
	h.up = p;
	try { callThrows(h, p, true); } catch (e) {}
	return h.up!.name;
}

function viaThrowStatement(): string {
	const h = new H();
	const p = new P("f");
	h.up = p;
	try { throwStatement(h, p, true); } catch (e) {}
	return h.up!.name;
}

function viaGetterThrows(): string {
	const h = new H();
	const p = new P("g");
	h.up = p;
	try { getterThrows(h, p, new G()); } catch (e) {}
	return h.up!.name;
}

function viaStoreInTry(): string {
	const h = new H();
	const p = new P("h");
	h.up = p;
	storeInTry(h, p, true);
	return h.up!.name;
}

function viaShortCircuit(): string {
	const h = new H();
	const p = new P("i");
	h.up = p;
	shortCircuit(h, p, false);
	return h.up!.name;
}

function storingPathKeeps(): string {
	const h = new H();
	earlyReturn(h, new P("kept"), false);
	return h.own!.name;
}

console.log([viaEarlyReturn(), viaForZero(), viaWhileZero(), viaForOfEmpty(), viaCallThrows(), viaThrowStatement(), viaGetterThrows(), viaStoreInTry(), viaShortCircuit(), storingPathKeeps()].join(" "));
