// @stdout: gen ...x2 | I say gen ...x1
// @stdout: rex woof x2 | I say rex woof x1
// @stdout: bit woof x2 | I say bit woof x1
// @stdout: tom! meow x2 (7) | I say tom! meow x1 (7)
// note: a method call through the base class runs the override of the object's class: from a function taking the base, from a base method through `this`, one level below an override that adds none, and for a subclass whose constructor passes a changed argument to `super(...)` before setting its own field. Same output on every lane.
class Animal {
	name: string;
	constructor(name: string) { this.name = name; }
	speak(times: int32): string { return `${this.name} ...x${times}`; }
	intro(): string { return "I say " + this.speak(1); }
}
class Dog extends Animal {
	speak(times: int32): string { return `${this.name} woof x${times}`; }
}
class Puppy extends Dog { age: int32 = 1; }
class Cat extends Animal {
	lives: int32 = 9;
	constructor(name: string) { super(name + "!"); this.lives = 7; }
	speak(times: int32): string { return `${this.name} meow x${times} (${this.lives})`; }
}
function talk(a: Animal): string { return a.speak(2); }
const zoo: Animal[] = [new Animal("gen"), new Dog("rex"), new Puppy("bit"), new Cat("tom")];
for (const a of zoo) { console.log(talk(a), "|", a.intro()); }
