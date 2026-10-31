// @stdout: abab#small
// @stdout: xx#big
// @stdout: [] 40
// @stdout: 55296,55296,35,115,109,97,108,108
// @stdout: abcdefghijklmnopqrstabcdefghijklmnopqrst#small
// @stdout: abcdabcd
// @stdout: zero-parameter-banner
// @stdout: nn#big
import { shout, wrap, hollow, banner } from "./stringNestWasm";

function units(s: string): string {
	const out: string[] = [];
	for (let i = 0; i < s.length; i = i + 1) { out.push(`${s.charCodeAt(i)}`); }
	return out.join(",");
}

console.log(wrap("ab", (s: string): int32 => shout(s).length));
console.log(wrap("x", (s: string): int32 => wrap(s, (t: string): int32 => shout(t).length).length));

const seen: string[] = [];
const empty = hollow((s: string): int32 => {
	const n = shout(s).length;
	seen.push(`${n}`);
	return n;
});
console.log(`[${empty}] ${seen.join(",")}`);

console.log(units(wrap("\uD800", (s: string): int32 => shout("\u{1F600}" + s).length)));
console.log(wrap("abcdefghijklmnopqrst", (s: string): int32 => wrap("q", (t: string): int32 => shout(t).length).length));
console.log(shout("abcd"));
console.log(banner());
console.log(wrap("n", (s: string): int32 => banner().length));
