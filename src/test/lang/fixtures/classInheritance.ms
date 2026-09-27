export class CrossA {
	x: int32;
	constructor(x: int32) { this.x = x; }
	getX(): int32 { return this.x; }
}

export class CrossB extends CrossA {
	y: int32;
	constructor(x: int32, y: int32) {
		super(x);
		this.y = y;
	}
	sum(): int32 { return this.x + this.y; }
}
