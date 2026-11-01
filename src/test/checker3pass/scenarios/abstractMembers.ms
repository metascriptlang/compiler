import { checkOnly } from "../helpers";

const SHAPE = `
abstract class Shape {
	abstract area(): number;
	describe(): string { return "shape"; }
}
`;

function errorsOf(body: string): string[] {
	return checkOnly(SHAPE + body).errors;
}

test "an abstract class cannot be constructed, with or without a constructor" {
	const errors = errorsOf(`
abstract class Named { name: string; constructor(n: string) { this.name = n; } }
const s = new Shape();
const n = new Named("x");
`);
	assert errors.length == 2 && errors[0] == "Cannot create an instance of the abstract class 'Shape'" && errors[1] == "Cannot create an instance of the abstract class 'Named'", errors.join("\n");
}

test "a concrete class answers every abstract method it inherits, itself or through a class between" {
	const errors = errorsOf(`
class Missing extends Shape {}
class Square extends Shape { area(): number { return 4; } }
abstract class Middle extends Shape {}
class Deep extends Middle {}
class Answered extends Shape { area(): number { return 1; } }
class Below extends Answered {}
const a: Shape = new Square();
const b: Shape = new Below();
`);
	assert errors.length == 2, errors.join("\n");
	assert errors[0] == "Non-abstract class 'Missing' does not implement inherited abstract member 'area' from class 'Shape'", errors[0];
	assert errors[1] == "Non-abstract class 'Deep' does not implement inherited abstract member 'area' from class 'Shape'", errors[1];
}

test "an abstract method lives in an abstract class, is not static and has no body" {
	const errors = errorsOf(`
class Plain { abstract m(): void; }
abstract class Static { static abstract make(): number; }
abstract class Bodied { abstract b(): number { return 1; } }
`);
	assert errors.length == 3, errors.join("\n");
	assert errors[0].startsWith("Abstract methods can only appear within an abstract class"), errors[0];
	assert errors[1].startsWith("'static' modifier cannot be used with 'abstract' modifier"), errors[1];
	assert errors[2] == "Method 'b' cannot have an implementation because it is marked abstract", errors[2];
}

test "super never reaches an abstract method" {
	const errors = errorsOf(`
class Square extends Shape {
	area(): number { return super.area(); }
}
`);
	assert errors.length == 1 && errors[0] == "Abstract method 'area' in class 'Shape' cannot be accessed via super expression", errors.join("\n");
}
