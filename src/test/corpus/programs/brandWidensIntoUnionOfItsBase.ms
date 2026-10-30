// @stdout: a3 s2 a3 a3 s:abc n:7 b3
// note: a brand meets a union that holds its base, not the brand: the brand widens to the base and is
// tagged into the base's slot, as an argument, an initializer and a return, for a brand over an array and
// over a string; the union holding the brand itself keeps taking it.
type Bytes = uint8[] & { __brand: "Bytes" };
type Id = string & { __brand: "Id" };
type Raw = string | uint8[];
type Tag = number | string;
type Holds = string | Bytes;

function describe(d: Raw): string {
	if (typeof d == "string") return `s${d.length}`;
	return `a${d.length}`;
}
function tagged(t: Tag): string {
	if (typeof t == "string") return `s:${t}`;
	return `n:${t}`;
}
function viaReturn(b: Bytes): Raw { return b; }
function holds(h: Holds): string {
	if (typeof h == "string") return `s${h.length}`;
	return `b${h.length}`;
}

const raw: uint8[] = [1, 2, 3];
const b = raw as Bytes;
const id = "abc" as Id;
const held: Raw = b;
console.log(describe(b), describe("xy"), describe(held), describe(viaReturn(b)), tagged(id), tagged(7), holds(b));
