// @xfail(raiser): the Raiser VM refuses `Ptr<void> as Ptr<int32>`, since its values have no byte representation
// @skip-js: the JS backend refuses `Ptr<void> as Ptr<int32>`, since a JS value has no byte representation
// @stdout: union=42,7 bang=42,7 bytes=42,42 typed=42 narrowed=42 sorted=1,2,3,5,8
struct Box { a: int32; b: int32; }

function viaUnion(p: Ptr<void> | null): string {
	const q = p as Ptr<int32>;
	return `${q[0]},${q[1]}`;
}

function viaBang(p: Ptr<void> | null): string {
	const q = p! as Ptr<int32>;
	return `${q[0]},${q[1]}`;
}

function byteOf(p: Ptr<void> | null): uint8 {
	const q = p as Ptr<uint8>;
	return q[0];
}

function byteOfBang(p: Ptr<void> | null): uint8 {
	return (p! as Ptr<uint8>)[0];
}

function typed(p: Ptr<Box> | null): int32 {
	const q = p as Ptr<int32>;
	return q[0];
}

function narrowed(p: Ptr<void> | null): int32 {
	if (p == null) return -1;
	const q = p as Ptr<int32>;
	return q[0];
}

function cmp(a: Ptr<void> | null, b: Ptr<void> | null): int32 {
	const x = (a! as Ptr<int32>)[0];
	const y = (b! as Ptr<int32>)[0];
	return x < y ? -1 : x > y ? 1 : 0;
}

function sort(view: Span<int32>): void {
	const base = view as Ptr<int32>;
	for (let i = 0; i < view.length; i += 1) {
		for (let j = 0; j + 1 < view.length - i; j += 1) {
			if (cmp((base + j) as Ptr<void>, (base + j + 1) as Ptr<void>) > 0) {
				const t = view[j];
				view[j] = view[j + 1];
				view[j + 1] = t;
			}
		}
	}
}

let box: Box = { a: 42, b: 7 };
const pv = box as Ptr<void>;
const cells: int32[] = [5, 3, 8, 1, 2];
sort(cells as Span<int32>);
console.log(`union=${viaUnion(pv)} bang=${viaBang(pv)} bytes=${byteOf(pv)},${byteOfBang(pv)} typed=${typed(box as Ptr<Box>)} narrowed=${narrowed(pv)} sorted=${cells.join(",")}`);
