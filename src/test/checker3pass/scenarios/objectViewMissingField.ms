import { checkOnly } from "../helpers";

test "as from a class to an object type it lacks a field of is refused" {
	const src = `
interface C { c: string; }
class Cell { t: int32 = 1; }
class Box<T> { v: T; constructor(v: T) { this.v = v; } }
class Foo { c: string = "foo"; }
type DF = distinct Foo;
type DCell = distinct Cell;
const a = new Cell() as C;
const b = new Box<string>("s") as C;
const d = (new Cell() as DCell) as C;
`;
	const text = checkOnly(src).errors.join("\n");
	assert text.contains("cannot convert Cell to C: it has no field 'c'"), "a class missing the field is refused: " + text;
	assert text.contains("cannot convert Box<string> to C: it has no field 'c'"), "a generic class instance missing the field is refused: " + text;
	assert text.contains("cannot convert DCell to C: it has no field 'c'"), "a distinct of a class missing the field is refused: " + text;
}

test "as from a class to an object type it holds every field of still converts" {
	const src = `
interface C { c: string; }
interface V { v: string; }
class A { c: string = "a"; }
class B extends A { t: int32 = 1; }
class Foo { c: string = "foo"; d: int32 = 3; }
class Box<T> { v: T; constructor(v: T) { this.v = v; } }
type DF = distinct Foo;
const a = new Foo() as C;
const b = new B() as C;
const d = (new Foo() as DF) as C;
const e = new Box<string>("s") as V;
`;
	const errors = checkOnly(src).errors;
	assert errors.length == 0, "a class, a subclass, a distinct and a generic instance holding the fields convert: " + errors.join("\n");
}

test "as to an object type outside the source's extends chain is refused when a member is not a held field" {
	const src = `
interface M { tag: string; name: () => string; }
interface P { tag: string; }
interface X { tag: string; extra: string; }
class K { tag: string = "t"; name(): string { return "k"; } }
class Sub extends K { }
class Bare { tag: string = "t"; }
const p: P = { tag: "t" };
const a = new K() as M;
const b = new Sub() as M;
const c = new Bare() as X;
const d = p as X;
`;
	const errors = checkOnly(src).errors;
	const text = errors.join("\n");
	assert text.contains("cannot convert K to M: its 'name' is a method, not a field"), "a method is not a field of the view: " + text;
	assert text.contains("cannot convert Sub to M: its 'name' is a method, not a field"), "an inherited method is not a field of the view: " + text;
	assert text.contains("cannot convert Bare to X: it has no field 'extra'"), "a class missing a field of an unrelated interface is refused: " + text;
	assert text.contains("cannot convert P to X: X is an interface with no run-time identity"), "an interface source down to a narrower interface is refused for its missing identity: " + text;
	assert errors.length == 4, "each refused cast reports one error: " + text;
}

test "as down an interface extends chain is refused for the missing run-time identity, not by the object view rule" {
	const src = `
interface S { a: string; }
interface C extends S { b: string; }
interface D extends C { d: string; }
interface M { name: () => string; }
class F { name: () => string = () => "f"; }
const s: S = { a: "x" };
const c = s as C;
const d = s as D;
const m = new F() as M;
`;
	const errors = checkOnly(src).errors;
	const text = errors.join("\n");
	assert text.contains("cannot convert S to C: C is an interface with no run-time identity"), "a child interface is refused for its missing identity: " + text;
	assert text.contains("cannot convert S to D: D is an interface with no run-time identity"), "a grandchild interface is refused for its missing identity: " + text;
	assert !text.contains("an object type cast reads the object's own fields"), "the object view rule does not fire down the chain: " + text;
	assert errors.length == 2, "a function-typed field held by a class is not refused: " + text;
}
