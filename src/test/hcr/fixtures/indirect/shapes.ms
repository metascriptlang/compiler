export class Shape {
	side: int32;

	constructor(side: int32) {
		this.side = side;
	}

	area(): int32 {
		return 0;
	}
}

export class Square extends Shape {
	area(): int32 {
		return this.side * this.side;
	}
}

export function makeSquare(side: int32): Shape {
	return new Square(side);
}

export function checked(value: int32): int32 {
	if (value < 0) throw new Error("negative");
	return value;
}
