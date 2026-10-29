// @exit: 1
// @stdout: before dog
// @xfail(danger): --danger drops the forced conversion check, so the Dog signature over a plain Animal reads Dog's memory instead of stopping
// @xfail(raiser): the Raiser stops at the same conversion with exit 1, but its 'raiser runtime error: invalid object conversion: …' goes to stderr, which the raiser cell keeps apart from the compared output
// note: the generic form of overloadSignatureNarrowedResultFatal: the instance of the implementation returns an Animal, the matched signature says Dog.

class Animal { kind(): string { return "animal"; } }
class Dog extends Animal { bark(): string { return "dog"; } }

function pick<T>(x: T, y: "rex"): Dog;
function pick<T>(x: T, y: string): Animal;
function pick<T>(x: T, y: string): Animal { return x == (1 as T) ? new Dog() : new Animal(); }

function main(): void {
	console.log(`before ${pick<int32>(1, "rex").bark()}`);
	console.log(`after ${pick<int32>(2, "rex").bark()}`);
}
main();
