// @exit: 1
// @stdout: before dog
// @xfail(danger): --danger drops the forced conversion check, so the Dog signature over a plain Animal reads Dog's memory instead of stopping
// note: an overload signature that returns a subclass of what its implementation returns is the author's word, as in TS; the call checks it where it is made, as `as Dog` does, so an implementation that returns a plain Animal stops at the call. A function, an extension and a generic function.

class Animal { kind(): string { return "animal"; } }
class Dog extends Animal { bark(): string { return "dog"; } }

function pick(x: "rex" | "fido"): Dog;
function pick(x: string): Animal;
function pick(x: string): Animal { return x == "rex" ? new Dog() : new Animal(); }

function main(): void {
	console.log(`before ${pick("rex").bark()}`);
	console.log(`after ${pick("fido").bark()}`);
}
main();
