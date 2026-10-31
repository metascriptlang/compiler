// @stdout: len=13 eq=true at=0:55296
// @stdout: len=13 eq=true at=5:56320
// @stdout: len=13 eq=true at=12:56319
// @stdout: len=14 eq=true at=0:55296
// @stdout: len=14 eq=true at=6:56320
// @stdout: len=14 eq=true at=13:56319
// @stdout: len=15 eq=true at=0:55296
// @stdout: len=15 eq=true at=7:56320
// @stdout: len=15 eq=true at=14:56319
// @stdout: len=13 eq=true at=0:65533
// @stdout: len=14 eq=true at=0:65533
// @stdout: len=15 eq=true at=0:65533
// @stdout: len=13 eq=true at=0:65533,3:55296
// @stdout: len=12 eq=true at=10:65533,11:56320
// @stdout: len=13 eq=true at=0:55357,1:56832
// @stdout: len=14 eq=true at=0:55357,1:56832
// @stdout: len=15 eq=true at=0:55357,1:56832
// @stdout: len=14 eq=true at=11:55296,12:55357,13:56832
// @stdout: len=17 eq=true at=
// @stdout: len=14 eq=true at=9:55296
// @stdout: len=0 eq=true at=
// @stdout: len=16 eq=true at=
// @stdout: len=17 eq=true at=
// @stdout: len=8 eq=true at=0:233,1:233,2:233,3:233,4:233,5:233,6:233,7:233
// @stdout: len=9 eq=true at=0:233,1:233,2:233,3:233,4:233,5:233,6:233,7:233,8:233
// @stdout: len=13 at=0:55296 ret=13
// @stdout: len=14 at=6:56320 ret=14
// @stdout: len=15 at=7:55296 ret=15
// @stdout: len=15 at=0:65533 ret=15
// @stdout: len=15 at=0:55357,1:56832 ret=15
import { echo, probe } from "./decodeWtf8Wasm";

function rep(c: string, n: int32): string {
	let out = "";
	for (let i = 0; i < n; i = i + 1) { out += c; }
	return out;
}

function marks(s: string): string {
	const out: string[] = [];
	for (let i = 0; i < s.length; i = i + 1) {
		const c = s.charCodeAt(i);
		if (c > 127) { out.push(`${i}:${c}`); }
	}
	return out.join(",");
}

function show(s: string): void {
	const r = echo(s);
	console.log(`len=${r.length} eq=${r == s} at=${marks(r)}`);
}

const a = "a";

show("\uD800" + rep(a, 12));
show(rep(a, 5) + "\uDC00" + rep(a, 7));
show(rep(a, 12) + "\uDBFF");
show("\uD800" + rep(a, 13));
show(rep(a, 6) + "\uDC00" + rep(a, 7));
show(rep(a, 13) + "\uDBFF");
show("\uD800" + rep(a, 14));
show(rep(a, 7) + "\uDC00" + rep(a, 7));
show(rep(a, 14) + "\uDBFF");

show("\uFFFD" + rep(a, 12));
show("\uFFFD" + rep(a, 13));
show("\uFFFD" + rep(a, 14));
show("\uFFFD" + rep(a, 2) + "\uD800" + rep(a, 9));
show(rep(a, 10) + "\uFFFD\uDC00");

show("\u{1F600}" + rep(a, 11));
show("\u{1F600}" + rep(a, 12));
show("\u{1F600}" + rep(a, 13));
show(rep(a, 11) + "\uD800\u{1F600}");

show(rep(a, 5) + "\0" + rep(a, 11));
show(rep(a, 4) + "\0" + rep(a, 4) + "\uD800" + rep(a, 4));

show("");
show(rep(a, 16));
show(rep(a, 17));
show(rep("\u00e9", 8));
show(rep("\u00e9", 9));

const seen: string[] = [];
for (let k = 0; k < 5; k = k + 1) {
	const n = probe(k, (s: string): int32 => {
		seen.push(`len=${s.length} at=${marks(s)}`);
		return s.length;
	});
	console.log(`${seen[k]} ret=${n}`);
}
