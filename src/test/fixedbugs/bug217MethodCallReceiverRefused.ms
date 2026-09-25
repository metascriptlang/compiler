// Symptom: a receiver that the free call refuses was accepted in method form: a `Ptr<T>` on a `this x: T` extension, and `this ref` did not parse, so const, temporary and value-parameter receivers could not be refused.
// Root cause: the receiver was never related as argument 0, so argument fit, the `Var` check and writeRefusal never saw it.
// Fix: the receiver goes through `relateArgs` like the free call; `ref this` names the spelling `this ref`.
import { compileToCWithStd } from "../helpers";

function receiverError217(body: string, decls: string = ""): string {
	const result = compileToCWithStd(`
struct S217 { n: int32; }
function get(this x: S217): int32 { return x.n; }
function bump(this ref x: S217): void { x.n = x.n + 1; }
function mk(): S217 { return { n: 10 }; }
${decls}
function main(): int32 {
	let arena: S217[1] = [{ n: 10 }];
	const ptr = arena[0] as Ptr<S217>;
	const s: S217 = { n: 10 };
	${body}
	return 0;
}
process.exit(main());
`);
	return result.ok ? "" : result.error;
}

test "bug217: a Ptr<T> receiver on a T extension is the free call's mismatch" {
	const dot = receiverError217("console.log(ptr.get());");
	const free = receiverError217("console.log(get(ptr));");
	assert dot.indexOf("Argument type mismatch in 'get' arg 0: got Ptr<S217>, expected S217", 0) >= 0, dot;
	assert free.indexOf("Argument type mismatch in 'get' arg 0: got Ptr<S217>, expected S217", 0) >= 0, free;
}

test "bug217: a const receiver cannot pass a this ref receiver" {
	const error = receiverError217("s.bump();");
	assert error.indexOf("cannot pass 's' to a 'ref' parameter — 's' is const (use 'let')", 0) >= 0, error;
}

test "bug217: a temporary cannot be a this ref receiver" {
	const error = receiverError217("mk().bump();");
	assert error.indexOf("'bump' arg 0: out parameter requires a variable, not an expression", 0) >= 0, error;
}

test "bug217: a value parameter cannot be a this ref receiver" {
	const error = receiverError217("use(s);", "function use(p: S217): void { p.bump(); }");
	assert error.indexOf("cannot mutate value-type parameter 'p'", 0) >= 0, error;
}

test "bug217: ref this names the spelling this ref" {
	const result = compileToCWithStd(`
struct S217 { n: int32; }
function bump(ref this x: S217): void { x.n = x.n + 1; }
`);
	assert !result.ok;
	assert result.error.indexOf("A mutable receiver is written 'this ref name: T', not 'ref this'", 0) >= 0, result.error;
}

test "bug217: a let receiver passes a this ref receiver" {
	assert receiverError217("let v: S217 = { n: 1 }; v.bump(); console.log(v.n);") == "";
}
