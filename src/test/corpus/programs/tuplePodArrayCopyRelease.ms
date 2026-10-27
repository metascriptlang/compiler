// @stdout: 2 9 7
// @stdout: 1 2
// @exit: 0

class Holder { value: [int32[4], int32]; }

function put(h: Holder, value: [int32[4], int32]): void {
	h.value = value;
}

function main(): void {
	const a: int32[4] = [1, 2, 3, 4];
	const h = new Holder();
	h.value = [[0, 0, 0, 0], 0];
	let t: [int32[4], int32] = [a, 7];
	put(h, t);
	t[0][1] = 9;
	console.log(`${h.value[0][1]} ${t[0][1]} ${h.value[1]}`);
	const m: HashMap<int32, [int32[4], int32]> = new HashMap();
	m.set(1, t);
	const got = m.get(1);
	console.log(`${m.size} ${got != null ? got[0][1] - 7 : -1}`);
}
main();
