// @stdout: 97,55296,98,0,99
// @stdout: 5
import { probe } from "./stringCallbackWasm";

const seen: string[] = [];
const n = probe((s: string): int32 => {
	for (let i = 0; i < s.length; i = i + 1) { seen.push(`${s.charCodeAt(i)}`); }
	return s.length;
});
console.log(seen.join(","));
console.log(`${n}`);
