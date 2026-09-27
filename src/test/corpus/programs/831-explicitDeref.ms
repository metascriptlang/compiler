// @stdout: deref-ok copy=7 hunger=20 name=bb inner=9 tags=3 interior=5 after=30 ref=3 refname=r
// note: `p[]` is the pointee of a Ptr<T> or Ref<T>: a field write, a `this ref` call, a copy out and a whole assignment through it reach the pointee on every backend, and a whole assignment through it keeps every other pointer into the pointee valid.

import { exit } from "std/process";

struct In { v: int32; }
struct Pet { hunger: int32; name: string; inner: In; tags: Vec<int32>; }

function feed(this ref pet: Pet, n: int32): void { pet.hunger = pet.hunger + n; }
function hungerOf(this pet: Pet): int32 { return pet.hunger; }

let arr: Pet[1] = [{ hunger: 1, name: "a", inner: { v: 1 }, tags: [1, 2] }];
const acc = arr[0] as Ptr<Pet>;
acc[].hunger = 4;
acc[].feed(3);
const snap = acc[];
acc[] = { hunger: 20, name: "bb", inner: { v: 9 }, tags: [7, 8, 9] };
if (snap.hunger != 7 || snap.name != "a") exit(1);
const hunger = acc[].hungerOf();
const name = arr[0].name;
const innerV = arr[0].inner.v;
const tags = arr[0].tags.length;

const inner = arr[0].inner as Ptr<In>;
acc[] = { hunger: 30, name: "c", inner: { v: 5 }, tags: [1] };

const r: Ref<Pet> = { hunger: 1, name: "r", inner: { v: 0 }, tags: [] };
r[].hunger = 2;
r[].feed(1);
const rs = r[];
r[] = rs;

console.log("deref-ok copy=" + snap.hunger.toString() + " hunger=" + hunger.toString() + " name=" + name
	+ " inner=" + innerV.toString() + " tags=" + tags.toString() + " interior=" + inner.v.toString()
	+ " after=" + acc[].hunger.toString() + " ref=" + r[].hunger.toString() + " refname=" + rs.name);
