// @stdout: comptime 4417 runtime 4417
// @exit: 0

struct Slot { a: uint64; b: uint8; }
struct Holder { slots: Slot[3]; count: uint64; }

function filled(): uint64 {
	let empty: uint64[4] = [];
	empty[2] = 5;
	let partial: uint64[4] = [1, 2];
	let held: Holder = { slots: [], count: 0 };
	held.slots[2].a = 9;
	let wide: uint64[31] = [];
	wide[30] = 1;
	return empty[2] + empty[3] + partial[1] + partial[3] + held.slots[2].a + held.slots[0].a
		+ (empty.length as uint64) * 100 + (partial.length as uint64) * 1000 + wide[30];
}

const atCompile = @comptime { return filled(); };
console.log(`comptime ${atCompile} runtime ${filled()}`);
