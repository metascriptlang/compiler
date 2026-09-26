// @stdout: 7 7 8
// A class with a constrained type parameter (`class Box<T extends Foo>`) instantiates: the
// constructor, a method that reads a field through the constraint, and a generic function over the
// same constraint all run. Before, the parameter reached the instance as `T:Foo` and the build
// stopped at "Unresolved type 'T:Foo'", then C emitted the field as `void*`.

interface Foo { zzqw: int32; }
interface Named { zzqw: int32; tag: string; }

class Box<T extends Foo> {
	v: T;
	constructor(v: T) { this.v = v; }
	get(): int32 { return this.v.zzqw; }
}

function getF<T extends Foo>(v: T): int32 { return v.zzqw; }

function main(): void {
	const f: Foo = { zzqw: 7 as int32 };
	const b = new Box<Foo>(f);
	const n: Named = { zzqw: 8 as int32, tag: "n" };
	const c = new Box<Named>(n);
	console.log(`${b.get()} ${getF(f)} ${c.get()}`);
}
main();
