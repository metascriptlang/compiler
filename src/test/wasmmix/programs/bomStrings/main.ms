// @stdout: 3:65279:98
// @stdout: 41:65279:78
// @stdout: 23:65279:101
// @stdout: 42:65279:78
// @stdout: 43:97:78
// @stdout: 41:65279:78
// @stdout: 1:65279:65279
// @stdout: 23:65279:101
// @stdout: 41:65279:78
// @stdout: 3:65279:98
// @stdout: 44
import { bomShort, bomLong, bomNonAscii, twoBoms, midBom, echo, probe } from "./bomStringsWasm";

function d(s: string): string {
	return `${s.length}:${s.charCodeAt(0)}:${s.charCodeAt(s.length - 1)}`;
}

console.log(d(bomShort()));
console.log(d(bomLong()));
console.log(d(bomNonAscii()));
console.log(d(twoBoms()));
console.log(d(midBom()));
console.log(d(echo("\uFEFFabcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN")));
console.log(d(echo("\uFEFF")));
console.log(d(echo("\uFEFFh\u00e9llo w\u00f6rld caf\u00e9 cr\u00e8me")));
const n = probe((s: string): int32 => {
	console.log(d(s));
	return s.length;
});
console.log(`${n}`);
