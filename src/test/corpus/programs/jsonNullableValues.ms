// @stdout: {"id":1,"n":null,"i":null,"f":null,"b":null,"c":null,"o":null,"arr":[],"ai":[],"ao":[],"sa":null,"du":null,"dus":[]}
// @stdout: {"id":2,"s":"q\"","n":"x","i":7,"f":1.5,"b":true,"c":"Green","o":{"x":3},"arr":["x",null],"ai":[null,4],"ao":[null,{"x":5}],"sa":["k"],"du":{"kind":"b","s":"z"},"dus":[{"kind":"a","v":1},{"kind":"b","s":"t"}]}
// @stdout: ["x",null] [null,2.5] null "a"
// @stdout: parsed {"id":3,"n":"y","i":null,"f":null,"b":false,"c":null,"o":null,"arr":[],"ai":[],"ao":[],"sa":null,"du":null,"dus":[]}
// note: JSON.stringify writes a null `T | null` value as null, field, array element or top level alike; an optional field `s?: string` holding null is left out, as TypeScript leaves out an absent property. Same output on every lane.
enum Color { Red, Green }
interface Inner { x: int32; }
interface ShapeA { kind: "a"; v: int32; }
interface ShapeB { kind: "b"; s: string; }
interface Rec {
	id: int32;
	s?: string;
	n: string | null;
	i: int32 | null;
	f: number | null;
	b: boolean | null;
	c: Color | null;
	o: Inner | null;
	arr: (string | null)[];
	ai: (int32 | null)[];
	ao: (Inner | null)[];
	sa: string[] | null;
	du: ShapeA | ShapeB | null;
	dus: (ShapeA | ShapeB)[];
}
interface Flat { id: int32; s?: string; n: string | null; i: int32 | null; f: number | null; b: boolean | null; c: Color | null; }

function main(): void {
	const absent: Rec = { id: 1, n: null, i: null, f: null, b: null, c: null, o: null, arr: [], ai: [], ao: [], sa: null, du: null, dus: [] };
	console.log(JSON.stringify(absent));
	const present: Rec = {
		id: 2, s: "q\"", n: "x", i: 7, f: 1.5, b: true, c: Color.Green, o: { x: 3 },
		arr: ["x", null], ai: [null, 4], ao: [null, { x: 5 }], sa: ["k"],
		du: { kind: "b", s: "z" }, dus: [{ kind: "a", v: 1 }, { kind: "b", s: "t" }],
	};
	console.log(JSON.stringify(present));
	const xs: (string | null)[] = ["x", null];
	const ns: (number | null)[] = [null, 2.5];
	const none: string | null = null;
	const some: string | null = "a";
	console.log(`${JSON.stringify(xs)} ${JSON.stringify(ns)} ${JSON.stringify(none)} ${JSON.stringify(some)}`);
	const r = JSON.parse<Flat>("{\"id\":3,\"n\":\"y\",\"i\":null,\"f\":null,\"b\":false,\"c\":null}");
	if (r.ok) {
		const back: Rec = { id: r.value.id, s: r.value.s, n: r.value.n, i: r.value.i, f: r.value.f, b: r.value.b, c: r.value.c, o: null, arr: [], ai: [], ao: [], sa: null, du: null, dus: [] };
		console.log("parsed " + JSON.stringify(back));
	} else {
		console.log("parse error " + r.error);
	}
}
main();
