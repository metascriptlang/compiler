// @stdout: inline:detail:7|one:detail|iface:detail:7|iface:detail:8
// @stdout: method:detail:9|nested:detail:10|pair:detail:list:3|generic:detail:11
// note: a type parameter is inferred from a field of an object literal argument, against an
// inline object type and a generic interface; a named candidate wins over the literal's own
// type, which is then retyped by it. Variants: a method, a nested interface, two type
// parameters, a method of a generic class.
interface Def<P> { name: string; parse: (m: string) => P; }
interface ToOptions<P> { to: Def<P>; params: P; }
interface FromOnly<P> { to: Def<P>; }
interface Wrap<P> { opts: ToOptions<P>; }
interface Pair<A, B> { first: Def<A>; second: Def<B>; a: A; b: B; }
interface Detail { id: string }
interface List { count: int32 }

function viaInline<P>(o: { to: Def<P>; params: P }): P { return o.params; }
function viaInterfaceOne<P>(o: FromOnly<P>): string { return o.to.name; }
function viaInterface<P>(o: ToOptions<P>): P { return o.params; }
function viaNested<P>(w: Wrap<P>): P { return w.opts.params; }
function viaPair<A, B>(p: Pair<A, B>): B { return p.b; }

class Router {
	navigate<P>(o: ToOptions<P>): string { return o.to.name; }
}
class Typed<T> {
	tag: T;
	constructor(tag: T) { this.tag = tag; }
	navigate<P>(o: ToOptions<P>): P { return o.params; }
}

const detail: Def<Detail> = { name: "detail", parse: (m: string): Detail => ({ id: m }) };
const list: Def<List> = { name: "list", parse: (m: string): List => ({ count: m.length }) };
const p: Detail = { id: "8" };
const r = new Router();
const t = new Typed<string>("x");

console.log(["inline:" + detail.name + ":" + viaInline({ to: detail, params: { id: "7" } }).id,
	"one:" + viaInterfaceOne({ to: detail }),
	"iface:" + detail.name + ":" + viaInterface({ to: detail, params: { id: "7" } }).id,
	"iface:" + detail.name + ":" + viaInterface({ to: detail, params: p }).id].join("|"));
console.log(["method:" + r.navigate({ to: detail, params: { id: "9" } }) + ":9",
	"nested:" + detail.name + ":" + viaNested({ opts: { to: detail, params: { id: "10" } } }).id,
	"pair:" + detail.name + ":" + list.name + ":" + String(viaPair({ first: detail, second: list, a: { id: "1" }, b: { count: 3 } }).count),
	"generic:" + detail.name + ":" + t.navigate({ to: detail, params: { id: "11" } }).id].join("|"));
