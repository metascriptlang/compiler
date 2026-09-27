interface Holder { val: string | int32; list: (string | int32)[]; name: string | null; }

function fieldArm(h: Holder): string { return h.val as string; }
function elementArm(h: Holder, i: int32): string { return h.list[i] as string; }
function nullableArm(h: Holder): string { return h.name as string; }

const h: Holder = { val: "hello" + 1, list: ["e" + 1, 5], name: "n" + 2 };
for (let i: int32 = 0; i < 3; i += 1) {
	const s = fieldArm(h);
	const e = elementArm(h, 0);
	const n = nullableArm(h);
	console.log(s + i + e + n);
}
console.log("end " + (h.val as string) + (h.list[0] as string) + (h.name as string));
