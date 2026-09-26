// @stdout: 2 q 3
// A generic function used where a concrete function type is expected is instantiated from that
// type (Nim paramTypesMatch → semGenerateInstance): as an argument to a non-generic parameter and
// as the initializer of a typed variable. Before, both emitted the uninstantiated name
// (C: "use of undeclared identifier 'twice…'", JS: ReferenceError).

function twice<T>(x: T): T[] { return [x, x]; }
function thrice<T>(x: T): T[] { return [x, x, x]; }

function apply(f: (x: int32) => int32[], v: int32): int32 { return f(v).length as int32; }

function main(): void {
	const g: (x: string) => string[] = twice;
	console.log(`${apply(twice, 4 as int32)} ${g("q")[0]} ${apply(thrice, 1 as int32)}`);
}
main();
