// @stdout: Mid Mid A G G A A G
// note: an overload taking the nearer ancestor wins over one taking a farther ancestor,
// with the nearer class imported under an alias or instantiated from a generic class.
import { A, BB as Mid, G } from "./mid";

class C extends Mid { c: int32 = 3; }
class D extends G<int32> { constructor() { super(4); } }
class E extends D {}

function f(x: A): string { return "A"; }
function f(x: Mid): string { return "Mid"; }
function h(x: A): string { return "A"; }
function h(x: G<int32>): string { return "G"; }

console.log([f(new C()), f(new Mid()), f(new A()), h(new D()), h(new E()), h(new A()), f(new G<int32>(5)), h(new G<int32>(6))].join(" "));
