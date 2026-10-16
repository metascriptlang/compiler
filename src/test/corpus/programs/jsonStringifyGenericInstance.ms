// @stdout: generic-instance-json all-ok
// note: a generic instance reaches the serializer macro as G<T>; it must read the instance's own fields, one-value literal fields included.

type G<T> = { v: T; w: int32 };
interface Box<T> { v: T; w: int32 }
class Cell<T> {
	v: T;
	w: int32 = 6;
	constructor(v: T) { this.v = v; }
}
type Holder = { g: G<true>; k: G<string> };
type Wrap<T> = { inner: G<T>; t: T };

function show<T>(x: T): string { return JSON.stringify(x); }

let failures = 0;
function check(name: string, got: string, want: string): void {
	if (got != want) {
		console.log("FAIL " + name + ": " + got + " != " + want);
		failures = failures + 1;
	}
}

const gTrue: G<true> = { v: true, w: 6 };
const gFalse: G<false> = { v: false, w: 6 };
const gStr: G<"a"> = { v: "a", w: 6 };
const gInt: G<int32> = { v: 5, w: 6 };
const gText: G<string> = { v: "x", w: 6 };
const box: Box<boolean> = { v: true, w: 6 };
const boxes: Box<int32>[] = [{ v: 1, w: 2 }, { v: 3, w: 4 }];
const holder: Holder = { g: { v: true, w: 1 }, k: { v: "z", w: 2 } };
const wrap: Wrap<int32> = { inner: { v: 3, w: 4 }, t: 9 };

check("true", JSON.stringify(gTrue), '{"v":true,"w":6}');
check("false", JSON.stringify(gFalse), '{"v":false,"w":6}');
check("string literal", JSON.stringify(gStr), '{"v":"a","w":6}');
check("int", JSON.stringify(gInt), '{"v":5,"w":6}');
check("string", JSON.stringify(gText), '{"v":"x","w":6}');
check("interface", JSON.stringify(box), '{"v":true,"w":6}');
check("class", JSON.stringify(new Cell<int32>(5)), '{"v":5,"w":6}');
check("array of instances", JSON.stringify(boxes), '[{"v":1,"w":2},{"v":3,"w":4}]');
check("fields that are instances", JSON.stringify(holder), '{"g":{"v":true,"w":1},"k":{"v":"z","w":2}}');
check("instance inside an instance", JSON.stringify(wrap), '{"inner":{"v":3,"w":4},"t":9}');
check("through a generic function true", show(gTrue), '{"v":true,"w":6}');
check("through a generic function false", show(gFalse), '{"v":false,"w":6}');

if (failures == 0) {
	console.log("generic-instance-json all-ok");
}
