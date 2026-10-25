// @stdout: optional=s a null|n 1 null|s a b|n 1 2
// @stdout: defaulted=s a 10|n 1 20|s a q|n 1 2
// @stdout: static=s a null|n 1 null
// @stdout: generic-class=g 5 null|gs s 2 null|g 5 q
// @stdout: generic-method=href /a|def detail|def detail true
// @stdout: extension=s a null|n 1 null
// A method overload whose omitted arguments are optional or defaulted is applicable, as the same
// overload set is for a free function, and the omitted arguments come from the winner's own
// defaults. The method overloads counted every parameter as required, so `h.hi("a")` reported
// "No matching overload"; a free extension overload passed the first overload's absent value in C.
class Hi {
	hi(a: number, b?: number): string { return `n ${a} ${b}`; }
	hi(a: string, b?: string): string { return `s ${a} ${b}`; }
	d(a: number, b: int32 = 20): string { return `n ${a} ${b}`; }
	d(a: string, b: string = "10"): string { return `s ${a} ${b}`; }
	static mk(a: string, b?: string): string { return `s ${a} ${b}`; }
	static mk(a: number, b?: number): string { return `n ${a} ${b}`; }
}
class G<T> {
	v: T;
	constructor(v: T) { this.v = v; }
	put(a: T, b?: string): string { return `g ${a} ${b}`; }
	put(a: string, b: number, c?: number): string { return `gs ${a} ${b} ${c}`; }
}
interface Def<P> { name: string; parse: (m: string) => P; }
interface Opts { replace?: boolean | null; }
interface Detail { id: string }
class R {
	navigate(href: string, options: Opts | null = null): string { return `href ${href}`; }
	navigate<P>(to: Def<P>, params: P, options: Opts | null = null): string {
		return `def ${to.name}${options != null ? " " + options.replace : ""}`;
	}
}
class E {}
function ex(this e: E, a: number, b?: number): string { return `n ${a} ${b}`; }
function ex(this e: E, a: string, b?: string): string { return `s ${a} ${b}`; }

const h = new Hi();
console.log(`optional=${h.hi("a")}|${h.hi(1)}|${h.hi("a", "b")}|${h.hi(1, 2)}`);
console.log(`defaulted=${h.d("a")}|${h.d(1)}|${h.d("a", "q")}|${h.d(1, 2)}`);
console.log(`static=${Hi.mk("a")}|${Hi.mk(1)}`);
const g = new G<number>(1);
console.log(`generic-class=${g.put(5)}|${g.put("s", 2)}|${g.put(5, "q")}`);
const detail: Def<Detail> = { name: "detail", parse: (m: string): Detail => ({ id: m }) };
const r = new R();
console.log(`generic-method=${r.navigate("/a")}|${r.navigate(detail, { id: "7" })}|${r.navigate(detail, { id: "7" }, { replace: true })}`);
const e = new E();
console.log(`extension=${e.ex("a")}|${e.ex(1)}`);
