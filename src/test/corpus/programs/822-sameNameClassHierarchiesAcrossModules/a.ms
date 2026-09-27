export class Animal {
	speak(): string {
		return "...";
	}
}

export class Dog extends Animal {
	speak(): string {
		return "woof";
	}
}

export class Pup extends Animal {
	legs: number = 4;
}

export function talkA(): string {
	const d: Animal = new Dog();
	const p: Animal = new Pup();
	return d.speak() + p.speak();
}
