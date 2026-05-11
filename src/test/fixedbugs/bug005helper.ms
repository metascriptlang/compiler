// Sibling helper for bug005 cross-module tests.
// Verifies that the methodToFunction lift + reachability `_init` seeding
// works when the class lives in one module and the `new ClassName(...)`
// site (or a child class) lives in another. Cross-module is the common
// case in real codebases — this guards against regressing the
// `classSym.modulePath` propagation in the reachability handler.

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
