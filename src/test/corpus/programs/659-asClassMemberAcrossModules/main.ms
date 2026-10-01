// @stdout: across carried=row:7,null plain=row:7 plainNullable=row:7
// note: `as Row | null` and `as Row` out of a union convert in a module that imports Row, and the JS membership test names the class through that import, so the split ESM output resolves it too. Same output on every backend.

import { Row } from "./lib/row";
import { carriedRow, plainRow, plainRowOrNull } from "./lib/convert";

function show(r: Row | null): string {
	return r == null ? "null" : `row:${r.value}`;
}

function main(): void {
	console.log("across"
		+ " carried=" + show(carriedRow(0)) + "," + show(carriedRow(1))
		+ " plain=" + show(plainRow(0))
		+ " plainNullable=" + show(plainRowOrNull(0)));
}
main();
