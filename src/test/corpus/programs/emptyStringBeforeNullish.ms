// @stdout: made=[][][][][][] maybe=[m][] slots=[][] field=[][e]
// note: `s ?? x` on a string that holds no null gives `s`, as in TS, even when `s` is empty: an empty string made by slice, join, replace, trim, a sized array or a field is not null. A `string | null` still takes the fallback only when it holds null.

const a = "a".slice(1);
const none: string[] = [];
const b = none.join(",");
const d = "x".replace("x", "");
const e = "  ".trim();
const f = "ab".split("")[0].slice(5);
let g = "";
g = g + "";
const made = `made=[${a ?? "A"}][${b ?? "B"}][${d ?? "D"}][${e ?? "E"}][${f ?? "F"}][${g ?? "G"}]`;

function maybe(on: boolean): string | null { return on ? "".slice(0) : null; }
const held = `maybe=[${maybe(false) ?? "m"}][${maybe(true) ?? "n"}]`;

const slots = new Array<string>(2);
const sized = `slots=[${slots[0] ?? "x"}][${slots[1] ?? "y"}]`;

interface Fields { s: string; t?: string }
const o: Fields = { s: "".slice(0) };
const { s = "d", t = "e" } = o;
console.log(`${made} ${held} ${sized} field=[${s}][${t}]`);
