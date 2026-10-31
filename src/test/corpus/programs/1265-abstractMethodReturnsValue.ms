// @stdout: 4 6.28 sq ci
// @stdout: 7 seven
// note: an abstract method declares its return type without a body, and a subclass's body answers through the base, directly and through an abstract class that extends another.
abstract class Shape {
	abstract area(): number;
	abstract name(): string;
	describe(): string { return this.name(); }
}
class Square extends Shape {
	area(): number { return 4; }
	name(): string { return "sq"; }
}
class Circle extends Shape {
	area(): number { return 6.28; }
	name(): string { return "ci"; }
}
const shapes: Shape[] = [new Square(), new Circle()];
console.log(`${shapes[0].area()} ${shapes[1].area()} ${shapes[0].describe()} ${shapes[1].describe()}`);

abstract class Labeled extends Shape {
	abstract label(times: int32): string;
}
class Tag extends Labeled {
	area(): number { return 7; }
	name(): string { return "tag"; }
	label(times: int32): string { return "seven".repeat(times); }
}
const t: Labeled = new Tag();
console.log(`${t.area()} ${t.label(1)}`);
