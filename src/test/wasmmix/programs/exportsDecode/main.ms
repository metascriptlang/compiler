// @stdout: 233,55
// @stdout: 62,104,114
// @stdout: t5 10
// @stdout: k0,k1,k2
// @stdout: 6
import { label, made, each } from "./exportsDecodeWasm";

function units(s: string): string {
	const out: string[] = [];
	for (let i = 0; i < s.length; i = i + 1) { out.push(`${s.charCodeAt(i)}`); }
	return out.join(",");
}

console.log(units(label(7)));
const long = label(-1);
console.log(`${long.length},${long.charCodeAt(0)},${long.charCodeAt(long.length - 1)}`);
const t = made(5);
console.log(`${t.text} ${t.count}`);
const seen: string[] = [];
const total = each(3, (s: string): int32 => {
	seen.push(s);
	return s.length;
});
console.log(seen.join(","));
console.log(`${total}`);
