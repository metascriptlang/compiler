// A closure written inside a condition (if, while, do-while, for, for-of, switch, case test) is lowered like one in a statement body:
// its destructuring, spreads and nullish reads reach C, JS and the Raiser in their lowered form.
// @stdout: if alice 7 | while 1 | do 1 | for 1 | forOf 2 | switch b | case alice | nested 9

struct Fixture { name: string; id: int64; }

function fixture(): Fixture { return { name: "alice", id: 7 }; }
function run(f: () => boolean): boolean { return f(); }
function pick(f: () => string): string { return f(); }
function count(f: () => int32): int32 { return f(); }

const parts: string[] = [];

if (run(() => { const { name, id } = fixture(); parts.push(`if ${name} ${id}`); return id == 7; })) {}

let w = 0;
while (w < 1 && run(() => { const [a, b] = [1, 2]; return a + b == 3; })) { w += 1; }
parts.push(`while ${w}`);

let dw = 0;
do { dw += 1; } while (run(() => { const { id } = fixture(); return id == 0; }));
parts.push(`do ${dw}`);

let fc = 0;
for (let i = 0; run(() => { const [lo, hi] = [i, 1]; return lo < hi; }); i += 1) { fc += 1; }
parts.push(`for ${fc}`);

let fo = 0;
for (const x of [count(() => { const [a, ...rest] = [1, 2, 3]; return rest.length as int32; })]) { fo = x; }
parts.push(`forOf ${fo}`);

switch (pick(() => { const [first, second] = ["a", "b"]; return second; })) {
	case "b": parts.push("switch b"); break;
	default: parts.push("switch other");
}

switch ("alice") {
	case pick(() => { const { name } = fixture(); return name; }): parts.push("case alice"); break;
	default: parts.push("case other");
}

if (run(() => run(() => { const [a, b] = [4, 5]; parts.push(`nested ${a + b}`); return true; }))) {}

console.log(parts.join(" | "));
