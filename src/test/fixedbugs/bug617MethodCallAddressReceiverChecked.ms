// Symptom: in method form a `Ptr<T>` or `Var<T>` receiver was not found, so neither its fit nor its emitted call matched the free call's; a lifecycle hook spelled `this self: Var<T>` was never bound to `T`, while `this ref self: T` was.
// Root cause: the receiver's registry name was its written wrapper (`Ptr`, `Var`), not the type it reaches; Nim binds a `var T` hook to `T` (semstmts.nim bindTypeHook, skipTypes tyVar) and relates a `ptr T` formal through its base.
// Fix: `this x: Var<T>` registers under `T` as `this ref x: T` does; a `Ptr<T>` receiver keeps its own name for hooks and is matched through its pointee.
import { compileToCWithStd } from "../helpers";

function emit617(decls: string, body: string): string {
	const result = compileToCWithStd(`
struct Pet617 { hunger: uint16; name: string; }
${decls}
function main(): int32 {
	let arena: Pet617[1] = [{ hunger: 10, name: "a" }];
	const ptr = arena[0] as Ptr<Pet617>;
	let pet: Pet617 = { hunger: 10, name: "a" };
	${body}
	return 0;
}
process.exit(main());
`);
	return result.ok ? result.value : "error: " + result.error;
}

test "bug617: a Ptr<T> receiver on a T value is the free call's mismatch" {
	const decl = "function feed(this p: Ptr<Pet617>, n: uint16): uint16 { return p.hunger - n; }";
	const dot = emit617(decl, "console.log(pet.feed(3));");
	const free = emit617(decl, "console.log(feed(pet, 3));");
	assert dot.indexOf("Argument type mismatch in 'feed' receiver: got Pet617, expected Ptr<Pet617>", 0) >= 0, dot;
	assert free.indexOf("Argument type mismatch in 'feed' arg 0: got Pet617, expected Ptr<Pet617>", 0) >= 0, free;
}

test "bug617: a method call on a Ptr<T> or Var<T> receiver emits the free call" {
	const ptrDecl = "function feed(this p: Ptr<Pet617>, n: uint16): uint16 { p.hunger = p.hunger - n; return p.hunger; }";
	assert emit617(ptrDecl, "console.log(ptr.feed(3));") == emit617(ptrDecl, "console.log(feed(ptr, 3));");
	const varDecl = "function rename(this p: Var<Pet617>, name: string): void { p.name = name; }";
	const dot = emit617(varDecl, "pet.rename(\"b\"); console.log(pet.name);");
	assert dot.indexOf("error:", 0) < 0, dot;
	assert dot == emit617(varDecl, "rename(pet, \"b\"); console.log(pet.name);");
}

test "bug617: a Ptr receiver to a primitive resolves like the free call" {
	const decls = "extern function cell617(): Ptr<int32>;\nfunction bump(this p: Ptr<int32>, by: int32): int32 { p[] = p[] + by; return p[]; }";
	const dot = emit617(decls, "const c = cell617(); console.log(c.bump(2));");
	assert dot.indexOf("error:", 0) < 0, dot;
	assert dot == emit617(decls, "const c = cell617(); console.log(bump(c, 2));");
}

test "bug617: a Var<T> hook receiver is a this ref hook receiver" {
	const hook = (receiver: string): string => emit617(
		"function onDestroy(" + receiver + "): void { console.log(\"destroy \" + self.name); }",
		"pet = { hunger: 1, name: \"b\" }; console.log(pet.name);");
	const byRef = hook("this ref self: Pet617");
	assert byRef.indexOf("error:", 0) < 0, byRef;
	assert hook("this self: Var<Pet617>") == byRef;
}
