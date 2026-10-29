// @exit: 1
// @stdout: before dog
// @xfail(danger): --danger drops the forced conversion check, so the Dog signature over a plain Animal reads Dog's memory instead of stopping
// @xfail(raiser): the Raiser stops at the same conversion with exit 1, but its 'raiser runtime error: invalid object conversion: …' goes to stderr, which the raiser cell keeps apart from the compared output
// note: the extension form of overloadSignatureNarrowedResultFatal: the signature returns Dog, the implementation a plain Animal for the second receiver.

class Animal { kind(): string { return "animal"; } }
class Dog extends Animal { bark(): string { return "dog"; } }

function fetch(this n: int32, x: "rex"): Dog;
function fetch(this n: int32, x: string): Animal;
function fetch(this n: int32, x: string): Animal { return n == 1 ? new Dog() : new Animal(); }

function main(): void {
	const one: int32 = 1;
	const two: int32 = 2;
	console.log(`before ${one.fetch("rex").bark()}`);
	console.log(`after ${two.fetch("rex").bark()}`);
}
main();
