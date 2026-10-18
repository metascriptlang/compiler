// @stdout: 10 4 3
// note: a @comptime call that constructs a subclass runs its super(...) when the parent class lives in another module: the std RangeError behind a number's toString and a user class imported here.

import { Shape } from "./shape";

class Square extends Shape {
	constructor() {
		super(4);
	}
}

@comptime function ten(): string {
	return (10).toString();
}

@comptime function squareSides(): int32 {
	return new Square().sides;
}

class Triangle extends Shape {
	constructor() {
		super(3);
	}
}

@comptime function triangleSides(): int32 {
	const t = new Triangle();
	return t.sides;
}

console.log(`${ten()} ${squareSides()} ${triangleSides()}`);
