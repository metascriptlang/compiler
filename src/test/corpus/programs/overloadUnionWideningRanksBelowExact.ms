// @stdout: union-widening ok 12
// note: an argument that is one member of a union parameter ranks below an overload that takes that member exactly, in either declaration order, as a nullable parameter already did: `f(x: int32)` beats `f(x: int32 | string)` for an int32 variable or literal, `f(x: string)` beats `f(x: string | null)`, and the union overload still takes what only it accepts; as a function, a method and an extension. Same output on C, JS and the Raiser.
let wrong = "";
let rows = 0;
function row(name: string, got: string, want: string): void {
	rows += 1;
	if (got != want) wrong += " " + name + "=" + got + "(want " + want + ")";
}

function uf(x: int32 | string): string { return "union"; }
function uf(x: int32): string { return "int32"; }
function fu(x: int32): string { return "int32"; }
function fu(x: int32 | string): string { return "union"; }
function nf(x: string | null): string { return "nullable"; }
function nf(x: string): string { return "string"; }
class Pick {
	take(x: int32 | string): string { return "union"; }
	take(x: int32): string { return "int32"; }
}
class Box { n: int32 = 1; }
function put(this b: Box, x: int32 | string): string { return "union"; }
function put(this b: Box, x: int32): string { return "int32"; }

const i: int32 = 3;
const s: string = "s";
const n: string | null = null;
row("union first, variable", uf(i), "int32");
row("union first, literal", uf(4), "int32");
row("union first, other member", uf(s), "union");
row("exact first, variable", fu(i), "int32");
row("exact first, other member", fu("t"), "union");
row("nullable, plain value", nf(s), "string");
row("nullable, null", nf(n), "nullable");
row("method, variable", new Pick().take(i), "int32");
row("method, other member", new Pick().take(s), "union");
row("extension, variable", new Box().put(i), "int32");
row("extension, literal", new Box().put(5), "int32");
row("extension, other member", new Box().put("u"), "union");
console.log(wrong == "" ? `union-widening ok ${rows}` : `union-widening wrong${wrong}`);
