import { checkOnly } from "../helpers";

const LITERAL = "must be initialized";
const NEW_LEAVES = "without a value: the class has no constructor";

const SRC_LITERAL_REFUSED = `
class Item { v: int32 = 7; }
struct Holds { xs: int32[]; }
class Bag<T> {
	n: int32;
	items: T[];
	r: Item;
	m: Map<string, int32>;
	f: () => int32;
	h: Holds;
	init: int32[] = [];
}
interface Shape { name: string; points: int32[]; }
const b: Bag<string> = { n: 1 };
const s: Shape = { name: "s" };
const h: Holds = {};
`;

const SRC_LITERAL_ACCEPTED = `
class Item { v: int32 = 7; }
struct P { x: int32; y: float64; }
type Sink = (text: string) => void;
class Bag {
	n: int32;
	p: P;
	text: string;
	opt?: int32[];
	maybe: Item | null;
	cb: Sink | null;
	items: int32[];
}
const b: Bag = { n: 1, items: [] };
const c: Bag = { items: [2], opt: [1], maybe: new Item() };
`;

const SRC_NEW_REFUSED = `
class Item { v: int32 = 7; }
class Rec { n: int32; items: int32[]; init: int32[] = []; }
class Child extends Rec { more: Item; }
class Gen<T> { xs: T[]; }
const a = new Rec();
const b = new Child();
const c = new Gen<string>();
`;

const SRC_NEW_ACCEPTED = `
class Item { v: int32 = 7; }
class Init { n: int32; items: int32[] = []; r: Item = new Item(); f: () => int32 = (): int32 => 1; opt?: Item; }
class Built { items: int32[]; constructor() { this.items = []; } }
class FromBuilt extends Built { n: int32; }
const a = new Init();
const b = new Built();
const c = new FromBuilt();
`;

function hasLine(errors: string[], part: string, tail: string): boolean {
	for (const e of errors) if (e.contains(part) && e.contains(tail)) return true;
	return false;
}

test "an object literal that omits a field whose type has no default value is refused" {
	const errors = checkOnly(SRC_LITERAL_REFUSED).errors;
	for (const name of ["items", "r", "m", "f", "h", "init", "points", "xs"]) {
		assert hasLine(errors, `field '${name}'`, LITERAL), `'${name}' must be refused: ` + errors.join("\n");
	}
	assert !hasLine(errors, "field 'n'", LITERAL), errors.join("\n");
}

test "value, optional and nullable fields may be omitted from an object literal" {
	const errors = checkOnly(SRC_LITERAL_ACCEPTED).errors;
	assert errors.length == 0, errors.join("\n");
}

test "new of a class without a constructor is refused when a field has no default value and no initializer" {
	const errors = checkOnly(SRC_NEW_REFUSED).errors;
	assert hasLine(errors, "'new Rec()' leaves 'items' without", NEW_LEAVES), errors.join("\n");
	assert hasLine(errors, "'new Child()' leaves 'items', 'more' without", NEW_LEAVES), errors.join("\n");
	assert hasLine(errors, "'new Gen()' leaves 'xs' without", NEW_LEAVES), errors.join("\n");
	assert !hasLine(errors, "'init'", NEW_LEAVES), errors.join("\n");
}

test "new is accepted when every such field has an initializer or a constructor assigns it" {
	const errors = checkOnly(SRC_NEW_ACCEPTED).errors;
	assert errors.length == 0, errors.join("\n");
}

test "a nullable function has a default value: null" {
	const src = `
type Sink = (text: string) => void;
interface Ctx { n: int32; a: Sink | null; b: ((t: string) => void) | null; }
const x: Ctx = { n: 1 };
function g(c: boolean): int32 {
	let f: (() => int32) | null;
	if (c) f = (): int32 => 1;
	return f == null ? 0 : 2;
}
`;
	const errors = checkOnly(src).errors;
	assert errors.length == 0, errors.join("\n");
}
