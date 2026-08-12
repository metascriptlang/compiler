// Fixture for src/test/guard/crossModuleSuperProto.ms — NOT part of any suite.
// The parent class must live in a DIFFERENT module than the subclass, so the
// consuming module has to forward-declare `Shape_init` itself.

export class Shape {
	w: number;
	constructor(w: number) {
		this.w = w;
	}
}
