// While a module's statements or a class's members are being checked, a rule that reaches that same module
// or class through its declaration still sees every statement and member. Compiled through the whole build,
// because the scenario helper checks class members on a path that does not reach these rules mid-walk.
import { compileToCWithStd } from "../helpers";

test "a top-level block moves its own local into an actor" {
	const c = compileToCWithStd(`
actor Sink { total: int32 = 0; frame(data: Buffer): int32 { this.total += data.length as int32; return this.total; } }
const sink = new Sink();
{ const b: Buffer = Buffer.alloc(3); console.log(await sink.frame(move b)); }
`);
	assert c.ok, c.ok ? "" : c.error;
}

test "a method of a class writing its own readonly field is refused" {
	const c = compileToCWithStd(`class C { readonly r: int32 = 1; bump(): void { this.r = 2; } }\nconsole.log(new C().r);`);
	assert !c.ok && c.error.contains("cannot assign to 'r' because it is a read-only property"), c.ok ? "accepted" : c.error;
}

test "a class constructing itself without a constructor names its field without a value" {
	const c = compileToCWithStd(`class D { v: int32; constructor(v: int32) { this.v = v; } }
class C { x: D; static make(): C { return new C(); } }
console.log(C.make() != null);`);
	assert !c.ok && c.error.contains("'new C()' leaves 'x' without a value"), c.ok ? "accepted" : c.error;
}
