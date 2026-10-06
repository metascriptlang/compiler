// @stdout: empty 0 0 0 marker 17 widths 1 16 8
// @exit: 0

import { exit } from "std/process";

struct Meta { key: uint64; flag: uint8; }
struct Empty { data: uint8[0]; marker: int32; }

function verify(): void {
	const none: Meta[0] = [];
	const bytes: uint8[0] = [];
	const empty: Empty = { data: [], marker: 17 };
	if (none.length != 0 || bytes.length != 0 || empty.data.length != 0 || empty.marker != 17) exit(1);
	if (sizeof(uint8[0]) != 1 || sizeof(Meta[0]) != 16 || sizeof(Empty) != 8) exit(2);
	console.log(`empty ${none.length} ${bytes.length} ${empty.data.length} marker ${empty.marker} widths ${sizeof(uint8[0])} ${sizeof(Meta[0])} ${sizeof(Empty)}`);
}
verify();
