import { checkOnly } from "../helpers";

const DECLS = `
interface Shape { name: string; }
interface Circle extends Shape { radius: number; }
interface Ring extends Circle { inner: number; }
interface Box<T> { name: string; v: T; }
interface Shelf<T> extends Box<T> { n: number; }
type Disc = { name: string; radius: number; };
class Ci implements Circle { name: string = "ci"; radius: number = 3; }
`;

const REFUSAL = "is an interface with no run-time identity, so \`as\` cannot check that the value is one";

function refusalMiss(body: string, shown: string): string {
	const errors = checkOnly(DECLS + body).errors;
	const text = errors.join("\\n");
	return errors.length == 1 && text.contains(shown) ? "" : "expected one '" + shown + "' for " + body + ", got: " + text;
}

test "an as down an interface extends chain is refused" {
	{ const miss = refusalMiss("function f(s: Shape): Circle { return s as Circle; }", "cannot convert Shape to Circle: Circle " + REFUSAL); assert miss == "", miss; }
	{ const miss = refusalMiss("function f(s: Shape): Ring { return s as Ring; }", "cannot convert Shape to Ring: Ring " + REFUSAL); assert miss == "", miss; }
	{ const miss = refusalMiss("function f(s: Circle): Ring { return s as Ring; }", "cannot convert Circle to Ring: Ring " + REFUSAL); assert miss == "", miss; }
}

test "a nullable interface down-conversion is refused with the same reason" {
	{ const miss = refusalMiss("function f(s: Shape | null): Circle | null { return s as Circle | null; }", "Circle " + REFUSAL); assert miss == "", miss; }
	{ const miss = refusalMiss("function f(s: Shape | null): Circle { return s as Circle; }", "Circle " + REFUSAL); assert miss == "", miss; }
}

test "a generic interface and an object type target are refused" {
	{ const miss = refusalMiss("function f(b: Box<int32>): Shelf<int32> { return b as Shelf<int32>; }", "Shelf<int32> " + REFUSAL); assert miss == "", miss; }
	{ const miss = refusalMiss("function f(s: Shape): Disc { return s as Disc; }", "it is an object type with no run-time identity"); assert miss == "", miss; }
}

test "an interface cast through unknown stays refused" {
	{ const miss = refusalMiss("function f(s: Shape): Circle { return s as unknown as Circle; }", "cannot check a conversion from unknown to Circle"); assert miss == "", miss; }
}

test "identity, up-conversion, null removal and object literals stay accepted" {
	const body = `
function same(c: Circle): Circle { return c as Circle; }
function up(c: Ring): Shape { return c as Shape; }
function cls(c: Ci): Circle { return c as Circle; }
function some(c: Circle | null): Circle { return c as Circle; }
function generic(s: Shelf<int32>): Box<int32> { return s as Box<int32>; }
function narrowed(s: Shape): number { if (s instanceof Ci) return s.radius; return 0; }
const lit = { name: "x", radius: 2 } as Circle;
`;
	const errors = checkOnly(DECLS + body).errors;
	assert errors.length == 0, errors.join("\\n");
}
