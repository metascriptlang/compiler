import { checkOnly } from "../helpers";

test "as into a distinct of a class from a value that is not an object is refused" {
	const src = `
class G<T> { get<K extends keyof T>(t: T, k: K): T[K] { return Reflect.get(t, k); } }
class Foo { c: string = "foo"; }
type DF = distinct Foo;
const xs: int32[] = [1, 2, 3];
const a = xs as Proxy<int32[], G<int32[]> >;
const b = "abc" as Proxy<string, G<string> >;
const n: int32 = 3;
const c = n as DF;
const f = (): int32 => 1;
const d = f as DF;
`;
	const text = checkOnly(src).errors.join("\n");
	assert text.contains("cannot convert int32[] to Proxy<int32[], G<int32[]>>: it is not an object"), "an array is refused: " + text;
	assert text.contains("cannot convert string to Proxy<string, G<string>>: it is not an object"), "a string is refused: " + text;
	assert text.contains("cannot convert int32 to DF: it is not an object"), "a number is refused: " + text;
	assert text.contains("cannot convert function to DF: it is not an object"), "a function is refused: " + text;
}

test "as into a distinct of a class from an object still converts" {
	const src = `
interface C { c: string; }
class G<T> { get<K extends keyof T>(t: T, k: K): T[K] { return Reflect.get(t, k); } }
class Foo { c: string = "foo"; }
class Sub extends Foo { }
type DF = distinct Foo;
const a = new Foo() as DF;
const b = new Sub() as DF;
const c: C = { c: "x" };
const p = new Proxy(c, new G<C>());
const q = p as Proxy<C, G<C> >;
const r = c as Proxy<C, G<C> >;
`;
	const errors = checkOnly(src).errors;
	assert errors.length == 0, "a class, a subclass, a Proxy and an interface value (checked at run time) convert: " + errors.join("\n");
}
