// @stdout: null true
// @stdout: from a union 3
// @stdout: its own member foo
// @stdout: field cleared true
// @stdout: proxy x true
// note: a distinct of a class takes its class's nullable layout, so `DF | null` is a pointer that null tests and narrowing read on C as they do for `Foo | null`, and `x as DF` out of a union holding Foo goes through the Foo member and its run-time check; the Bar case of that check is distinctOfClassInUnionFatal

interface C { c: string; }
class G<T> { get<K extends keyof T>(t: T, k: K): T[K] { return Reflect.get(t, k); } }
class Foo { c: string = "foo"; d: int32 = 3; }
class Bar { c: string = "bar"; }
type DF = distinct Foo;
type P = Proxy<C, G<C> >;

class Holder { slot: DF | null = null; }

function maybe(on: boolean): DF | null { return on ? new Foo() as DF : null; }
function pick(o: Foo | Bar): DF { return o as DF; }
function keep(o: DF | Bar): DF { return o as DF; }
function maybeProxy(on: boolean): P | null {
	const c: C = { c: "x" };
	return on ? new Proxy(c, new G<C>()) : null;
}

const none = maybe(false);
console.log("null " + (none == null).toString());
const some = maybe(true);
if (some != null) console.log("narrowed " + (some as Foo).c);
console.log("cast back " + ((some as DF) as Foo).c);
console.log("from a union " + (pick(new Foo()) as Foo).d.toString());
console.log("its own member " + (keep(new Foo() as DF) as Foo).c);
const h = new Holder();
h.slot = maybe(true);
h.slot = maybe(true);
console.log("field " + (h.slot == null ? "null" : (h.slot as Foo).c));
h.slot = null;
console.log("field cleared " + (h.slot == null).toString());
const p = maybeProxy(true);
console.log("proxy " + (p as P).c + " " + (maybeProxy(false) == null).toString());
