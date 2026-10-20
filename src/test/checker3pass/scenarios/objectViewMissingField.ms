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
