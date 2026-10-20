// @stdout: p d x 3
// note: an element access whose key is a string literal reads the property it names, on an inferred object type with a non-identifier name and on an interface; same output on every lane.
interface Counter { plain: string; hits: int32; }

const o = { plain: "p", "data-probe": "d" };
const c: Counter = { plain: "x", hits: 2 };
c["hits"] = c["hits"] + 1;
console.log(o["plain"] + " " + o["data-probe"] + " " + c["plain"] + " " + String(c["hits"]));
