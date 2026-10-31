// randomUUID() is RFC 4122 version 4 on every draw: 36 chars, dashes at 8/13/18/23, version digit 4,
// variant digit in 8..b, lowercase hex elsewhere; and 2000 draws hold no duplicate.
//
// @stdout: draws 2000 bad 0 duplicates 0
// @exit: 0
// @skip-js: std/crypto has only a C backend (index.cms over runtime/crypto); there is no index.jms
// @skip-raiser: std/crypto has only a C backend (index.cms over runtime/crypto); there is no raiser random

import { randomUUID } from "std/crypto";

const hex = "0123456789abcdef";
const seen = new Set<string>();
let bad = 0;
let duplicates = 0;
for (let i = 0; i < 2000; i++) {
	const r = randomUUID();
	if (!r.ok) {
		bad++;
		continue;
	}
	const u = r.value;
	let good = u.length == 36 && u.charAt(14) == "4" && "89ab".indexOf(u.charAt(19), 0) >= 0;
	for (let j = 0; j < 36 && good; j++) {
		const c = u.charAt(j);
		if (j == 8 || j == 13 || j == 18 || j == 23) good = c == "-";
		else good = hex.indexOf(c, 0) >= 0;
	}
	if (!good) bad++;
	if (seen.has(u)) duplicates++;
	seen.add(u);
}
console.log(`draws 2000 bad ${bad} duplicates ${duplicates}`);
