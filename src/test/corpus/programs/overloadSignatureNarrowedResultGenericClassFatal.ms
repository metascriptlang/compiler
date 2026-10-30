// @exit: 1
// @stdout: before fancy
// @xfail(danger): --danger drops the forced conversion check, so the Fancy<Dog> signature over a plain Holder<Dog> reads Fancy's memory instead of stopping
// @skip-js: JS names the failed generic instance by its emitted class (`Holder_…__ref_Dog is not Fancy<Dog>`) where C writes `Holder<Dog>`
// note: the generic-class form of overloadSignatureNarrowedResultFatal: the signature returns a subclass instance `Fancy<Dog>` of what the implementation returns, `Holder<Dog>`, and the second call's implementation returns the plain parent.

class Animal { kind(): string { return "animal"; } }
class Dog extends Animal { bark(): string { return "dog"; } }
class Holder<T> { v: T; constructor(v: T) { this.v = v; } }
class Fancy<T> extends Holder<T> { tag(): string { return "fancy"; } }

function make(x: "rex" | "fido"): Fancy<Dog>;
function make(x: string): Holder<Dog>;
function make(x: string): Holder<Dog> { return x == "rex" ? new Fancy<Dog>(new Dog()) : new Holder<Dog>(new Dog()); }

function main(): void {
	console.log(`before ${make("rex").tag()}`);
	console.log(`after ${make("fido").tag()}`);
}
main();
