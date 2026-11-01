// randomBytesSync(n) returns n bytes for every size, including the empty request, and two draws differ.
// A draw above the OS's single-call limit (1 MB) still arrives whole: a short read is looped on.
//
// @stdout: size 0 ok true len 0|size 1 ok true len 1|size 255 ok true len 255|size 1048576 ok true len 1048576 distinct true nonzero true|negative ok false
// @exit: 0
// @skip-raiser: std/crypto has only a C backend (index.cms over runtime/crypto); there is no raiser random

import { randomBytesSync, toHex } from "std/crypto";

function row(size: int32): string {
	const a = randomBytesSync(size);
	if (!a.ok) return `size ${size} ok false`;
	let line = `size ${size} ok true len ${a.value.length}`;
	if (size >= 1048576) {
		const b = randomBytesSync(size);
		const hexA = toHex(a.value);
		line += ` distinct ${b.ok && hexA != toHex(b.value)}`;
		line += ` nonzero ${hexA.indexOf("00".repeat(4096), 0) < 0}`;
	}
	return line;
}

const rows = [row(0), row(1), row(255), row(1048576)];
console.log(rows.join("|") + `|negative ok ${randomBytesSync(-1).ok}`);
