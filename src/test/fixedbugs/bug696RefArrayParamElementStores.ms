// Symptom: an element store through a `ref` array parameter (`arr[0] = 9` with `ref arr: int32[]`, also `string[]`, struct elements and a `this ref` receiver's array field) reached C codegen with an unresolved type (kind=48); JS was right.
// Root cause: on an assignment target the checker typed the var parameter `Var<T[]>` instead of its pointee, so the index access over it found no element type; the reference dereferences a var expression wherever it is used.
// Fix: a var parameter is typed as its pointee on every use, read or write.

struct Pt696 { x: int32; }
struct Bag696 { items: int32[]; }

function putInt(ref arr: int32[]): void { arr[0] = 9; }
function putString(ref s: string[]): void { s[0] = "z"; }
function setPoints(ref ps: Pt696[]): void { ps[0] = { x: 9 }; ps[1].x = 4; }
function grow(ref ps: Pt696[]): void { ps.push({ x: 1 }); }
function poke(this ref b: Bag696): void { b.items[0] = 77; }

test "bug696: element stores through a ref array parameter" {
	let a: int32[] = [1, 2];
	let t: string[] = ["a"];
	putInt(a);
	putString(t);
	assert a[0] == 9;
	assert t[0] == "z";
}

test "bug696: struct elements, push and a this ref field through a ref parameter" {
	let ps: Pt696[] = [{ x: 1 }, { x: 2 }];
	setPoints(ps);
	grow(ps);
	assert ps[0].x == 9;
	assert ps[1].x == 4;
	assert ps.length == 3;
	let bag: Bag696 = { items: [1, 2] };
	bag.poke();
	assert bag.items[0] == 77;
}
