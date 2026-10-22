// @stdout: fn:7|fnExplicit:8|method:9|methodExplicit:10|overload:11|overloadExplicit:12|href:/a
// @stdout: nested:13@1,2|nestedExplicit:14@3,4|nestedOverload:15@5,6|wrap:16|wrapNested:17@7,8
// note: a struct type parameter inferred from a sibling field types the object literal written
// for it as that struct, as an explicit type argument does. Variants: a free function, a method,
// an overloaded method, inferred and explicit, a struct with a nested struct field, and the
// literal one interface deeper.
interface Def<P> { name: string; show: (p: P) => string; }
interface ToOptions<P> { to: Def<P>; params: P; }
interface Wrap<P> { opts: ToOptions<P>; }
struct Detail { id: string }
struct Point { x: int32; y: int32 }
struct Placed { id: string; at: Point }

function go<P>(to: ToOptions<P>): string { return to.to.show(to.params); }
function goWrapped<P>(w: Wrap<P>): string { return w.opts.to.show(w.opts.params); }

class R {
	go<P>(to: ToOptions<P>): string { return to.to.show(to.params); }
}
class O {
	go(href: string): string { return "href:" + href; }
	go<P>(to: ToOptions<P>): string { return to.to.show(to.params); }
}

const detail: Def<Detail> = { name: "detail", show: (p: Detail): string => p.id };
const placed: Def<Placed> = { name: "placed", show: (p: Placed): string => p.id + "@" + String(p.at.x) + "," + String(p.at.y) };
const r = new R();
const o = new O();

console.log(["fn:" + go({ to: detail, params: { id: "7" } }),
	"fnExplicit:" + go<Detail>({ to: detail, params: { id: "8" } }),
	"method:" + r.go({ to: detail, params: { id: "9" } }),
	"methodExplicit:" + r.go<Detail>({ to: detail, params: { id: "10" } }),
	"overload:" + o.go({ to: detail, params: { id: "11" } }),
	"overloadExplicit:" + o.go<Detail>({ to: detail, params: { id: "12" } }),
	o.go("/a")].join("|"));
console.log(["nested:" + go({ to: placed, params: { id: "13", at: { x: 1, y: 2 } } }),
	"nestedExplicit:" + r.go<Placed>({ to: placed, params: { id: "14", at: { x: 3, y: 4 } } }),
	"nestedOverload:" + o.go({ to: placed, params: { id: "15", at: { x: 5, y: 6 } } }),
	"wrap:" + goWrapped({ opts: { to: detail, params: { id: "16" } } }),
	"wrapNested:" + goWrapped({ opts: { to: placed, params: { id: "17", at: { x: 7, y: 8 } } } })].join("|"));
