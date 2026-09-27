// Symptom: `p[]` was a parse error, so a Ptr<T> account had no written deref for a `this ref` call, a copy out or a whole assignment.
// Root cause: the postfix `[` always parsed an index, never a deref.
// Fix: `x[]` parses as a HiddenDeref flagged ExplicitDeref, the checker types it as the pointee of a Ptr<T> or Ref<T>, and JS writes `x[] = v` into the pointee in place (msValAssign).

struct In221 { v: int32; }
struct Pet221 { hunger: int32; name: string; inner: In221; tags: Vec<int32>; }

function feed221(this ref pet: Pet221, n: int32): void { pet.hunger = pet.hunger + n; }
function hunger221(this pet: Pet221): int32 { return pet.hunger; }
function pet221(h: int32): Pet221 { return { hunger: h, name: "a", inner: { v: 1 }, tags: [1, 2] }; }

test "bug221: a field write through p[] reaches the pointee" {
	let arr: Pet221[1] = [pet221(1)];
	const acc = arr[0] as Ptr<Pet221>;
	acc[].hunger = 4;
	assert arr[0].hunger == 4;
}

test "bug221: a this ref method and a value method called on p[]" {
	let arr: Pet221[1] = [pet221(4)];
	const acc = arr[0] as Ptr<Pet221>;
	acc[].feed221(3);
	assert arr[0].hunger == 7;
	assert acc[].hunger221() == 7;
}

test "bug221: const s = p[] is a copy" {
	let arr: Pet221[1] = [pet221(7)];
	const acc = arr[0] as Ptr<Pet221>;
	let snap = acc[];
	snap.hunger = 99;
	assert arr[0].hunger == 7;
}

test "bug221: p[] = v overwrites every field, nested struct, string and Vec" {
	let arr: Pet221[1] = [pet221(7)];
	const acc = arr[0] as Ptr<Pet221>;
	const inner = arr[0].inner as Ptr<In221>;
	acc[] = { hunger: 20, name: "bb", inner: { v: 9 }, tags: [7, 8, 9] };
	assert arr[0].hunger == 20;
	assert arr[0].name == "bb";
	assert arr[0].tags.length == 3;
	assert inner.v == 9;
}

test "bug221: the same four forms through a Ref<T>" {
	const r: Ref<Pet221> = { hunger: 1, name: "a", inner: { v: 1 }, tags: [1, 2] };
	r[].hunger = 2;
	r[].feed221(1);
	const copy = r[];
	r[] = { hunger: 40, name: "r", inner: { v: 2 }, tags: [] };
	assert copy.hunger == 3;
	assert r[].hunger == 40;
	assert r[].name == "r";
}
