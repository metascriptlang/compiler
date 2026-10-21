// @stdout: {"name":"a","nul":null}
// @stdout: {"name":"b","nick":"n","both":"x","nul":"y"}
// @stdout: {"inner":{"id":1},"list":[{"id":2},{"id":3,"tag":"t"}]}
// @stdout: {"label":"b"} {"label":"b","hint":"h"} {"label":"d"}
// @stdout: {"value":7} {"value":7,"extra":8}
// @stdout: {"b":"x"} {"a":1,"y":null} {"x":1}
// @stdout: {"kind":"circle","r":1} {"kind":"sq","s":2}
// @stdout: {"id":4} [{"id":5,"memo":"m"},{"id":6}]
// @stdout: parsed {"name":"c","nul":null} nick=null both=null
// @stdout: missing name: field 'name': expected string, got null
// note: a field written `name?` and holding null is left out of JSON.stringify, as TypeScript leaves out an absent property; a field typed `T | null` without `?` still writes null. The `?` mark rides on the struct type, so it reaches nested, array, class, inherited, generic, intersection, anonymous, union-variant and imported shapes. JSON.parse reads a missing optional key as null and still refuses a missing required one.
import { Remote } from "./shapes";

interface Person { name: string; nick?: string; both?: string | null; nul: string | null; }
interface Inner { id: int32; tag?: string; }
interface Outer { inner: Inner; list: Inner[]; note?: string; }
class Box { label: string = "b"; hint?: string; }
class Derived extends Box { more?: string; }
interface Wrap<T> { value: T; extra?: T; }
interface Base { a?: string; }
interface Child extends Base { b: string; c?: int32; }
interface A { a: int32; }
type AB = A & { z?: string; y: string | null };
type Anon = { x: int32; y?: string };
type Shape = { kind: "circle"; r: int32; fill?: string } | { kind: "sq"; s: int32; fill?: string };

function main(): void {
	const absent: Person = { name: "a", nul: null };
	console.log(JSON.stringify(absent));
	const present: Person = { name: "b", nick: "n", both: "x", nul: "y" };
	console.log(JSON.stringify(present));
	const o: Outer = { inner: { id: 1 }, list: [{ id: 2 }, { id: 3, tag: "t" }] };
	console.log(JSON.stringify(o));
	const box = new Box();
	const hinted = new Box();
	hinted.hint = "h";
	const d = new Derived();
	d.label = "d";
	console.log(`${JSON.stringify(box)} ${JSON.stringify(hinted)} ${JSON.stringify(d)}`);
	const w: Wrap<int32> = { value: 7 };
	const we: Wrap<int32> = { value: 7, extra: 8 };
	console.log(`${JSON.stringify(w)} ${JSON.stringify(we)}`);
	const c: Child = { b: "x" };
	const ab: AB = { a: 1, y: null };
	const an: Anon = { x: 1 };
	console.log(`${JSON.stringify(c)} ${JSON.stringify(ab)} ${JSON.stringify(an)}`);
	const circle: Shape = { kind: "circle", r: 1 };
	const sq: Shape = { kind: "sq", s: 2 };
	console.log(`${JSON.stringify(circle)} ${JSON.stringify(sq)}`);
	const rm: Remote = { id: 4 };
	const rs: Remote[] = [{ id: 5, memo: "m" }, { id: 6 }];
	console.log(`${JSON.stringify(rm)} ${JSON.stringify(rs)}`);
	const r = JSON.parse<Person>(JSON.stringify({ name: "c", nul: null } as Person));
	if (r.ok) {
		console.log(`parsed ${JSON.stringify(r.value)} nick=${r.value.nick == null ? "null" : r.value.nick} both=${r.value.both == null ? "null" : r.value.both}`);
	} else {
		console.log("parse error " + r.error);
	}
	const missing = JSON.parse<Person>("{\"nick\":\"n\",\"nul\":null}");
	console.log(missing.ok ? "missing name: ok" : "missing name: " + missing.error);
}
main();
