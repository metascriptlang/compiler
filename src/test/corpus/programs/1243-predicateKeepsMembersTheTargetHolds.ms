// @stdout: woof meow 3
// @stdout: animal 4 z!
class Animal { name: string = "a"; }
class Dog extends Animal { bark(): string { return "woof"; } }
class Cat extends Animal { meow(): string { return "meow"; } }
function isAnimal(x: Dog | Cat | string): x is Animal {
	return typeof x != "string";
}
function sound(x: Dog | string): string {
	if (isAnimal(x)) return x.bark();
	return x.length.toString();
}
function pick(x: Dog | Cat | string): string {
	if (isAnimal(x)) {
		if (x instanceof Dog) return x.bark();
		return x.meow();
	}
	return x.length.toString();
}
function other(x: Dog | Cat | string): string {
	if (!isAnimal(x)) return x + "!";
	return x instanceof Cat ? "animal" : x.bark().length.toString();
}
console.log(sound(new Dog()), pick(new Cat()), sound("abc"));
console.log(other(new Cat()), other(new Dog()) , other("z"));
