// @stdout: person={"name":"a","age":3} shape={"kind":"s","side":4} parsed=b5 folded={"name":"c","age":7}
// note: a std macro whose helper lives in a std module of its own (`JSON.stringify` → `jsonValueOf` → the union detector and its `DiscInfo`; `JSON.parse` → the decoder) runs in its module's environment on every target, also inside `@comptime`; only the std modules the Raiser's prelude declares itself take the Raiser's std there.
interface Person { name: string; age: int32; }
type Shape = { kind: "c"; r: int32 } | { kind: "s"; side: int32 };
const p: Person = { name: "a", age: 3 };
const sh: Shape = { kind: "s", side: 4 };
const r = JSON.parse<Person>("{\"name\":\"b\",\"age\":5}");
const parsed = r.ok ? r.value.name + r.value.age.toString() : "error";
const folded = @comptime {
	const q: Person = { name: "c", age: 7 };
	return JSON.stringify(q);
};
console.log("person=" + JSON.stringify(p) + " shape=" + JSON.stringify(sh) + " parsed=" + parsed + " folded=" + folded);
