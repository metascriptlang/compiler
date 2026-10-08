// @stdout: ret 7|init 7|arg 7|assign 7|field 7|cast 7|arr 70|deep 70|null 70|num 3|near mid 30|from union mid 3
// note: a subclass instance stored into a union whose member is one of its base classes takes that base's slot after an upcast: by return, initializer, argument, assignment, an interface field, `as Base`, an array element, two levels deep, under a nullable union and next to a number. With two ancestors in the union it takes the nearer one. Same output on C, JS and the Raiser.
class Base {
	constructor() {}
	get(): number { return 1; }
}
class Mid extends Base {
	v: number;
	constructor(v: number) { super(); this.v = v; }
	get(): number { return this.v; }
}
class Leaf extends Mid {
	constructor(v: number) { super(v); }
	get(): number { return this.v * 10; }
}
interface Cfg { to: Base | number; }
function show(x: Base | string): string { return typeof x === "string" ? x : x.get().toString(); }
function showNum(x: Base | number): string { return typeof x === "number" ? x.toString() : (x as Base).get().toString(); }
function showNull(x: Base | string | null): string { return x == null ? "null" : show(x); }
function showNear(x: Base | Mid | string): string {
	if (typeof x === "string") return x;
	return (x instanceof Mid ? "mid " : "base ") + (x as Base).get().toString();
}
function load(flag: boolean): Base | string {
	if (flag) { return new Mid(7); }
	return "none";
}
const out: string[] = [];
out.push("ret " + show(load(true)));
const held: Base | string = new Mid(7);
out.push("init " + show(held));
out.push("arg " + show(new Mid(7)));
let slot: Base | string = "s";
slot = new Mid(7);
out.push("assign " + show(slot));
const m = new Mid(7);
const cfg: Cfg = { to: m };
out.push("field " + showNum(cfg.to));
out.push("cast " + showNum({ to: m as Base }.to));
const arr: (Base | number)[] = [new Leaf(7), 3];
out.push("arr " + showNum(arr[0]));
out.push("deep " + show(new Leaf(7)));
out.push("null " + showNull(new Leaf(7)));
out.push("num " + showNum(arr[1]));
out.push("near " + showNear(new Leaf(3)));
const u: Mid | string = new Mid(3);
out.push("from union " + showNear(u));
console.log(out.join("|"));
