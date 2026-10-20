// E2E C: the temps a for-of over an array introduces count at int64, so an array past 2^31 elements cannot wrap.

import { compileToC } from "../helpers";

test "E2E C: a for-of over an array counts at int64" {
	const r = compileToC(`
		function count(words: string[]): int32 {
			let n: int32 = 0;
			for (const w of words) { if (w.length > 0) n += 1; }
			return n;
		}
		console.log(count(["a"]));
	`);
	assert r.ok;
	const c = r.ok ? r.value : "";
	assert c.contains("int64_t dollaridx_");
	assert c.contains("int64_t dollarlen_");
	assert !c.contains("double dollarlen_");
}
