import { checkOnly } from "../helpers";

const UNASSIGNED = "has no initializer and is not assigned on every path of the constructor";

const SRC_REFUSED = `
class Node2 { v: int32 = 1; }
class Bad<T> {
	items: T[];
	branch: int32[];
	viaMethod: int32[];
	early: int32[];
	inArrow: int32[];
	m: Map<string, int32>;
	inner: Node2;
	f: () => int32;
	constructor(c: boolean) {
		if (c) { this.branch = []; }
		this.setup();
		const k = (): void => { this.inArrow = []; };
		k();
		if (c) return;
		this.early = [];
	}
	setup(): void { this.viaMethod = []; }
}
`;

const SRC_ACCEPTED = `
class Node2 { v: int32 = 1; }
struct P { x: int32; }
class Ok<T> {
	items: T[];
	both: int32[];
	thrown: int32[];
	inner: Node2;
	f: () => int32;
	n: int32;
	p: P;
	text: string;
	opt?: int32[];
	maybe: int32[] | null;
	init: int32[] = [];
	constructor(c: boolean) {
		this.items = [];
		if (c) { this.both = [1]; } else { this.both = []; }
		if (!c) throw new Error("x");
		this.thrown = [];
		this.inner = new Node2();
		this.f = (): int32 => 1;
	}
}
class Record { items: int32[]; }
`;

test "a reference field the constructor does not assign on every path is refused at the field" {
	const errors = checkOnly(SRC_REFUSED).errors;
	const names = ["items", "branch", "viaMethod", "early", "inArrow", "m", "inner", "f"];
	for (const name of names) {
		let found = false;
		for (const e of errors) if (e.contains(`Field '${name}' ${UNASSIGNED}`)) found = true;
		assert found, `'${name}' must be refused: ` + errors.join("\n");
	}
}

test "fields assigned on every path, value fields, optional and initialized fields are accepted" {
	const errors = checkOnly(SRC_ACCEPTED).errors;
	assert errors.length == 0, errors.join("\n");
}

test "a definite-assignment field marker is refused with the reason" {
	const text = checkOnly(`class Bag { items!: int32[]; constructor() {} }`).errors.join("\n");
	assert text.contains("a definite-assignment '!' is refused"), text;
}
