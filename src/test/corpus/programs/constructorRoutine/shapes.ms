export class Shape {
	name: string;
	sides: number;
	constructor(name: string, sides: number = 3) {
		this.name = name;
		this.sides = sides;
	}
	describe(): string {
		return this.name + ":" + this.sides.toString();
	}
}

export class Square extends Shape {
	edge: number;
	constructor(edge: number) {
		super("square", 4);
		this.edge = edge;
	}
}

export class Crate<T> {
	item: T;
	count: number;
	constructor(item: T, count: number = 1) {
		this.item = item;
		this.count = count;
	}
}

export class Marker {
	tag: string = "marker";
}
