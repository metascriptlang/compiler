import { checkOnly } from "../helpers";

function errorsAt(source: string, text: string): string {
	const at: string[] = [];
	for (const e of checkOnly(source).ctx.errors) {
		if (e.message.contains(text)) at.push(`${e.line}:${e.column}`);
	}
	return at.join(",");
}

const BASE = `
class A {
	x: int32 = 1;
	m(): int32 { return this.x; }
}
`;

test "a field write, a method call and a super property read before super() are refused" {
	const source = BASE + `class B extends A {
	constructor() {
		this.x = 2;
		this.m();
		super.m();
		super();
	}
}
`;
	assert errorsAt(source, "'super' must be called before accessing 'this'") == "8:3,9:3";
	assert errorsAt(source, "'super' must be called before accessing a property of 'super'") == "10:3";
}

test "this after super() on every path is accepted, and a path without super() is refused" {
	const accepted = BASE + `class B extends A {
	constructor(flag: boolean) {
		if (flag) { super(); } else { super(); }
		this.x = 3;
		const read = (): int32 => this.m();
	}
}
`;
	assert checkOnly(accepted).errors.length == 0, checkOnly(accepted).errors.join("\n");
	const oneArm = BASE + `class B extends A {
	constructor(flag: boolean) {
		if (flag) { super(); }
		this.x = 3;
	}
}
`;
	assert errorsAt(oneArm, "'super' must be called before accessing 'this'") == "9:3";
}

test "an argument of super() that reads this is refused, and a class without a parent is not checked" {
	const source = BASE + `class B extends A {
	constructor() { super(this.x); }
}
class C {
	n: int32 = 0;
	constructor() { this.n = 1; }
}
`;
	assert errorsAt(source, "'super' must be called before accessing 'this'") == "7:24";
}

test "this in a loop after super() is accepted, for and while with continue alike" {
	const source = BASE + `class B extends A {
	constructor(n: int32) {
		super();
		for (let i = 0; i < n; i++) {
			if (i > 2) { this.x += i; }
		}
		let j = 0;
		while (j < n) {
			if (j == 3) { j++; continue; }
			this.x += j;
			j++;
		}
	}
}
`;
	assert checkOnly(source).errors.length == 0, checkOnly(source).errors.join("\n");
}

test "this in a loop before super() is refused, as the path into the loop has not passed it" {
	const source = BASE + `class B extends A {
	constructor(n: int32) {
		for (let i = 0; i < n; i++) { this.x = i; }
		super();
	}
}
`;
	assert errorsAt(source, "'super' must be called before accessing 'this'") == "8:33";
}
