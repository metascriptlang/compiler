// @exit: 1
// @stdout: before x
// @xfail(danger): --danger drops the forced conversion check, so the plain value is read as a Proxy instead of stopping
// note: a type alias that evaluates to a Proxy is checked as the Proxy is: the Proxy itself casts through it, and a plain object literal stops with "invalid object conversion: Object is not ProxyCell<C, G<C>>", naming the literal `Object` on every backend

interface C { c: string; }
class G<T> { get<K extends keyof T>(t: T, k: K): T[K] { return Reflect.get(t, k); } }
type Wrap<T> = T extends string ? T : Proxy<T, G<T> >;

const c: C = { c: "x" };
const p = new Proxy(c, new G<C>());
const ok = p as Wrap<C>;
console.log("before " + ok.c);
const w = c as Wrap<C>;
console.log("after " + w.c);
