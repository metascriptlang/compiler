export class Base {
	n: number;

	constructor(n: number) {
		this.n = n;
	}
}

export class Sub extends Base {
	constructor(n: number) {
		super(n + 1);
	}
}

export class GBase<T> {
	n: number;

	constructor(n: number) {
		this.n = n;
	}
}

export class GSub extends GBase<int32> {
	constructor(n: number) {
		super(n + 2);
	}
}
