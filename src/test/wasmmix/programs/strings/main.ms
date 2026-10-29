// @stdout: 97,98,99,97,98,99
// @stdout:
// @stdout: 55357,56832,55357,56832
// @stdout: 55296,55296
// @stdout: 56320,56320
// @stdout: 97,0,98,97,0,98
// @stdout: 97,98,99,100,101,102,103,104,105,106,107,108,109,110,111,112,113,114,115,116,117,118,119,120,121,122,65,66,67,68,69,70,71,72,73,74,75,76,77,78,97,98,99,100,101,102,103,104,105,106,107,108,109,110,111,112,113,114,115,116,117,118,119,120,121,122,65,66,67,68,69,70,71,72,73,74,75,76,77,78
// @stdout: 97,98,99,100,101,102,103,104,105,106,107,108,109,110,111,112,113,114,115,116,55296,117,118,119,120,121,122,65,66,67,68,69,70,71,72,73,74,75,76,77,97,98,99,100,101,102,103,104,105,106,107,108,109,110,111,112,113,114,115,116,55296,117,118,119,120,121,122,65,66,67,68,69,70,71,72,73,74,75,76,77
// @stdout: 120,0,121,55357,56832
// @stdout: 55296
// @stdout:
import { twice, pick } from "./stringsWasm";

function units(s: string): string {
	const out: string[] = [];
	for (let i = 0; i < s.length; i = i + 1) { out.push(`${s.charCodeAt(i)}`); }
	return out.join(",");
}

const cases: string[] = [
	"abc",
	"",
	"\u{1F600}",
	"\uD800",
	"\uDC00",
	"a\0b",
	"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN",
	"abcdefghijklmnopqrst\uD800uvwxyzABCDEFGHIJKLM",
];
for (const c of cases) { console.log(units(twice(c))); }
console.log(units(pick(0)));
console.log(units(pick(1)));
console.log(units(pick(2)));
