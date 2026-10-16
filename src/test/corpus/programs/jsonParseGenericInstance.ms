// @stdout: generic-instance-json-parse all-ok
// note: JSON.parse<T> reads a generic instance through its implementation, as the encoder does, at the top level, as a field and as an array element.

type G<T> = { v: T; w: int32 };
interface Box<T> { v: T; w: int32 }
type Holder = { g: G<int32>; k: G<string> };
interface BHolder { b: Box<int32>; s: Box<string> }
interface BArr { bs: Box<int32>[] }

let failures = 0;
function check(name: string, ok: boolean): void {
	if (!ok) {
		console.log("FAIL " + name);
		failures = failures + 1;
	}
}

const gInt = JSON.parse<G<int32>>(JSON.stringify({ v: 5, w: 6 } as G<int32>));
check("alias int", gInt.ok && gInt.value.v == 5 && gInt.value.w == 6);
const gText = JSON.parse<G<string>>(JSON.stringify({ v: "x", w: 6 } as G<string>));
check("alias string", gText.ok && gText.value.v == "x" && gText.value.w == 6);
const box = JSON.parse<Box<int32>>(`{"v":5,"w":6}`);
check("interface", box.ok && box.value.v == 5 && box.value.w == 6);
const holder = JSON.parse<Holder>(`{"g":{"v":1,"w":2},"k":{"v":"z","w":3}}`);
check("alias fields", holder.ok && holder.value.g.v == 1 && holder.value.k.v == "z" && holder.value.k.w == 3);
const bHolder = JSON.parse<BHolder>(`{"b":{"v":5,"w":6},"s":{"v":"q","w":7}}`);
check("interface fields", bHolder.ok && bHolder.value.b.v == 5 && bHolder.value.s.v == "q" && bHolder.value.s.w == 7);
const bArr = JSON.parse<BArr>(`{"bs":[{"v":1,"w":2},{"v":3,"w":4}]}`);
check("array of instances", bArr.ok && bArr.value.bs.length == 2 && bArr.value.bs[1].v == 3);
const wrong = JSON.parse<G<int32>>(`{"v":"x","w":6}`);
check("wrong kind refused", !wrong.ok && wrong.error.includes("field 'v'"));

if (failures == 0) {
	console.log("generic-instance-json-parse all-ok");
}
