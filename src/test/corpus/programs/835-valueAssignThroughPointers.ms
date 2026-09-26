// @stdout: through deref=20/20 elem=30 field=5 ref=9 vec=3/3 swap=21 interior=2 global=2 classField=5 refParam=6 refField=6
// note: a whole value assigned into a location — through `p[]`, into an element or a field, into a global, a class field or a `ref` parameter — is seen through every pointer to that location, and a Vec takes the new length in place. The Raiser VM used to rebind (the old object stayed behind every pointer) and dropped `p[] = v`; JS left a Vec behind a pointer at its old length.
struct Pet { hunger: int32; name: string; }
struct In { v: int32; }
struct Pair { a: In; b: In; }
class Box { pos: In = { v: 0 }; }

let g: In = { v: 1 };
const gp = g as Ptr<In>;

function setWhole(ref x: In): void { x = { v: 6 }; }
function setField(ref x: In): void { x.v = 6; }

function main(): int32 {
	let arr: Pet[1] = [{ hunger: 1, name: "a" }];
	const acc = arr[0] as Ptr<Pet>;
	acc[] = { hunger: 20, name: "bb" };
	const deref = arr[0].hunger.toString() + "/" + acc[].hunger.toString();

	arr[0] = { hunger: 30, name: "cc" };
	const elem = acc.hunger;

	const holder: Pair = { a: { v: 1 }, b: { v: 2 } };
	const fieldPtr = holder.a as Ptr<In>;
	holder.a = { v: 5 };

	const r: Ref<Pet> = { hunger: 1, name: "r" };
	const alias = r;
	r[] = { hunger: 9, name: "z" };

	let v: Vec<int32> = [1, 2];
	const vp = v as Ptr<Vec<int32>>;
	vp[] = [3, 4, 5];

	let s: Pair = { a: { v: 1 }, b: { v: 2 } };
	const pa = s.a as Ptr<In>;
	s = { a: s.b, b: s.a };

	g = { v: 2 };
	const b = new Box();
	const bp = b.pos as Ptr<In>;
	b.pos = { v: 5 };
	let whole: In = { v: 0 };
	setWhole(whole);
	let part: In = { v: 0 };
	setField(part);

	console.log("through deref=" + deref + " elem=" + elem.toString() + " field=" + fieldPtr.v.toString()
		+ " ref=" + alias.hunger.toString() + " vec=" + v.length.toString() + "/" + vp[].length.toString()
		+ " swap=" + s.a.v.toString() + s.b.v.toString() + " interior=" + pa.v.toString()
		+ " global=" + gp.v.toString() + " classField=" + bp.v.toString()
		+ " refParam=" + whole.v.toString() + " refField=" + part.v.toString());
	return 0;
}
main();
