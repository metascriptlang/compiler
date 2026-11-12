// @stdout: a b c d e f
// note: a constructor takes a parameter only when nothing that can leave it runs before the store. A local handed to `new` for the last time and still reachable through an Unowned edge lives to the end of the caller's scope when the constructor throws first: from a call, a throw statement, a field initializer, `super`, before a parameter property after `super`, and from a getter.
class P { name: string; constructor(name: string) { this.name = name; } }
class H { up: Unowned<P> | null = null; }
class G { get v(): int32 { throw new Error("g"); } }
function boom(on: boolean): void { if (on) throw new Error("x"); }
let armed = true;
function boomInt(): int32 { if (armed) throw new Error("x"); return 1; }

class AfterCall { own: P; constructor(p: P, on: boolean) { boom(on); this.own = p; } }
class AfterThrow { own: P; constructor(p: P, on: boolean) { if (on) throw new Error("x"); this.own = p; } }
class AfterField { m: int32 = boomInt(); own: P; constructor(p: P) { this.own = p; } }
class Base { constructor(on: boolean) { boom(on); } }
class AfterSuper extends Base { own: P; constructor(p: P, on: boolean) { super(on); this.own = p; } }
class PropAfterSuper extends Base { constructor(public own: P, on: boolean) { super(on); } }
class AfterGetter { own: P; constructor(p: P, g: G) { const n = g.v; this.own = p; } }

function afterCall(): string {
	const h = new H();
	const p = new P("a");
	h.up = p;
	try { const k = new AfterCall(p, true); } catch (e) {}
	return h.up!.name;
}

function afterThrow(): string {
	const h = new H();
	const p = new P("b");
	h.up = p;
	try { const k = new AfterThrow(p, true); } catch (e) {}
	return h.up!.name;
}

function afterField(): string {
	const h = new H();
	const p = new P("c");
	h.up = p;
	try { const k = new AfterField(p); } catch (e) {}
	return h.up!.name;
}

function afterSuper(): string {
	const h = new H();
	const p = new P("d");
	h.up = p;
	try { const k = new AfterSuper(p, true); } catch (e) {}
	return h.up!.name;
}

function propAfterSuper(): string {
	const h = new H();
	const p = new P("e");
	h.up = p;
	try { const k = new PropAfterSuper(p, true); } catch (e) {}
	return h.up!.name;
}

function afterGetter(): string {
	const h = new H();
	const p = new P("f");
	h.up = p;
	try { const k = new AfterGetter(p, new G()); } catch (e) {}
	return h.up!.name;
}

console.log([afterCall(), afterThrow(), afterField(), afterSuper(), propAfterSuper(), afterGetter()].join(" "));
