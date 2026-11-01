// @stdout: "bytes2:3"
// @stdout: {"b":"bytes2:3"}
// @stdout: "name:x"
// @stdout: {"n":"name:x"}
// @stdout: "id:7"
// @stdout: {"n":"id:7"}
// @stdout: ["bytes2:3"]
// note: a `toJSON` extension declared on a brand (array, string or number base) is called by JSON.stringify at top level, as a field and as an array element; same output on every lane.
type Bytes2 = uint8[] & { __brand: "Bytes2" };
type Name = string & { __brand: "Name" };
type Id = number & { __brand: "Id" };

function toJSON(this b: Bytes2): string {
	return "bytes2:" + b.length.toString();
}
function toJSON(this n: Name): string {
	return "name:" + n;
}
function toJSON(this n: Id): string {
	return "id:" + (n as number).toString();
}

const raw: uint8[] = [1, 2, 3];
const b = raw as Bytes2;
console.log(JSON.stringify(b));
console.log(JSON.stringify({ b: b }));
console.log(JSON.stringify("x" as Name));
console.log(JSON.stringify({ n: "x" as Name }));
console.log(JSON.stringify(7 as Id));
console.log(JSON.stringify({ n: 7 as Id }));
console.log(JSON.stringify([b]));
