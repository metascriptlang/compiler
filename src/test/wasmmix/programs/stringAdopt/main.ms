// @stdout: [abc|abc!]
// @stdout: [|!]
// @stdout: [h<233>|h<233>!]
// @stdout: [<8364>|<8364>!]
// @stdout: [<55357><56832>|<55357><56832>!]
// @stdout: [<55296>|<55296>!]
// @stdout: [ab:7:<233>]
// @stdout: [:-3:]
// @stdout: [<55357><56832>:0:z]
// @stdout: []|[abc]|[<233><8364>]
// @stdout: [<233>ab|ab|3]
// @stdout: [||0]
// @stdout: [<55357><56832>|<55357><56832>|2]
// @stdout: h<233>,h<233>! 5
// @stdout: <55357><56832>x,<55357><56832>x! 7
// @stdout: 82 62
// @stdout: 60040000
// @stdout: 2400
import { keep, echo, join2, relabel, relay, lengthOf, Label } from "./stringAdoptWasm";

function show(s: string): string {
	let out = "";
	for (let i = 0; i < s.length; i = i + 1) {
		const c = s.charCodeAt(i);
		if (c < 128) { out += s.slice(i, i + 1); } else { out += `<${c}>`; }
	}
	return out;
}

function runRelay(s: string): string {
	const seen: string[] = [];
	const n = relay(s, (t: string): int32 => {
		seen.push(show(t));
		return t.length;
	});
	return `${seen.join(",")} ${n}`;
}

function label(text: string, tag: string, count: int32): Label {
	return { text: text, tag: tag, count: count };
}

function showLabel(l: Label): string {
	return `[${show(l.text)}|${show(l.tag)}|${l.count}]`;
}

const cases: string[] = ["abc", "", "h\u00E9", "\u20AC", "\u{1F600}", "\uD800"];
for (const c of cases) { console.log(`[${show(keep(c))}]`); }

console.log(`[${show(join2("ab", 7, "\u00E9"))}]`);
console.log(`[${show(join2("", -3, ""))}]`);
console.log(`[${show(join2("\u{1F600}", 0, "z"))}]`);

const echoed: string[] = [];
for (const c of ["", "abc", "\u00E9\u20AC"]) { echoed.push(`[${show(echo(c))}]`); }
console.log(echoed.join("|"));

console.log(showLabel(relabel(label("ab", "\u00E9", 5))));
console.log(showLabel(relabel(label("", "", 9))));
console.log(showLabel(relabel(label("\u{1F600}", "", 1))));

console.log(runRelay("h\u00E9"));
console.log(runRelay("\u{1F600}x"));

let ascii = "";
for (let i = 0; i < 40; i = i + 1) { ascii += "x"; }
let wide = "";
for (let i = 0; i < 30; i = i + 1) { wide += "\u00E9"; }
console.log(`${keep(ascii).length} ${keep(wide).length}`);

let bigAscii = "";
for (let i = 0; i < 2000; i = i + 1) { bigAscii += "a"; }
let bigWide = "";
for (let i = 0; i < 1000; i = i + 1) { bigWide += "\u00E9"; }
let total = 0;
for (let i = 0; i < 20000; i = i + 1) { total += keep(i % 2 == 0 ? bigAscii : bigWide).length; }
console.log(`${total}`);

let mega = "a";
for (let i = 0; i < 20; i = i + 1) { mega = mega + mega; }
let sizeOk = 0;
for (let i = 0; i < 2400; i = i + 1) { if (lengthOf(mega) == 1048576) { sizeOk += 1; } }
console.log(`${sizeOk}`);
