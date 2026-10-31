// @stdout: 3 5 3 -1
// @stdout: 3 5 7 -1
type Held = uint8[] | string;

function sizeOf(x: Held): int32 {
	if (typeof x == "string") return x.length as int32;
	return x.length as int32;
}
function sizeOrNone(x: uint8[] | null): int32 {
	return x == null ? -1 : x.length as int32;
}
function viaUnion(x: Buffer | string): int32 { return sizeOf(x); }
function viaNull(x: Buffer | null): int32 { return sizeOrNone(x); }

const raw: uint8[] = [1, 2, 3];
const buf = raw as Buffer;
console.log(viaUnion(buf), viaUnion("hello"), viaNull(buf), viaNull(null));

const held: Buffer | string = "seven!!";
const widened: Held = held;
console.log(sizeOf(buf), sizeOf("hello"), sizeOf(widened), viaNull(null));
