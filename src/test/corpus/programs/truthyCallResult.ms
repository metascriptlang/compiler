// @stdout: FT | FT | TF | 10 | FTT | FT | FTT | FT | F | FTFT | FFTT | 2 2 | FTFFTF | FFT | FFFTT
// note: a call result in a condition gets the test its type needs, as a local does: a string call, method, closure or built-in result is falsy when empty, a float call result when 0 or NaN, a nullable call result is read once, also as a value under ! and in an instance field initializer. C applied `!` to the msString temp and died at the C compiler; the Raiser read every string and float as false.

function empty(): string { return ""; }
function word(): string { return "w"; }
function zero(): number { return 0; }
function notANumber(): number { return NaN; }
function maybeText(v: string, on: boolean): string | null { return on ? v : null; }
let left = 3;
function countdown(): number | null { left = left - 1; return left; }
class Named {
	name: string;
	constructor(n: string) { this.name = n; }
	label(): string { return this.name; }
}
function probe<T>(read: () => T): string { return read() ? "T" : "F"; }
function absent(v: string): boolean { return !maybeText(v, true); }
class Defaults {
	shown: string = maybeText("", true) ? "T" : "F";
	hidden: boolean = !maybeText("s", true);
	pick: (v: string) => string = (v: string): string => maybeText(v, true) ? "T" : "F";
}
class Derived extends Named {
	marked: string = maybeText("m", true) || maybeText("", true) ? "T" : "F";
	constructor() { super("d"); }
}

const parts: string[] = [];
parts.push((empty() ? "T" : "F") + (word() ? "T" : "F"));
let r = "";
if (empty()) { r += "T"; } else { r += "F"; }
if (word()) { r += "T"; } else { r += "F"; }
parts.push(r);
parts.push((!empty() ? "T" : "F") + (!word() ? "T" : "F"));
let loops = 0;
while (empty()) { loops++; break; }
while (word()) { loops += 10; break; }
parts.push(`${loops}`);
parts.push(((empty() && true) ? "T" : "F") + ((word() && true) ? "T" : "F") + ((empty() || word()) ? "T" : "F"));
const named = new Named("");
const full = new Named("n");
parts.push((named.label() ? "T" : "F") + (full.label() ? "T" : "F"));
parts.push((String(0).slice(1) ? "T" : "F") + ("ab".slice(1) ? "T" : "F") + ("ab".trim() ? "T" : "F"));
const read: () => string = empty;
const readWord: () => string = word;
parts.push((read() ? "T" : "F") + (readWord() ? "T" : "F"));
const local: string = empty();
parts.push(local ? "T" : "F");
parts.push((maybeText("", true) ? "T" : "F") + (maybeText("s", true) ? "T" : "F") + (maybeText("s", false) ? "T" : "F") + (!maybeText("", true) ? "T" : "F"));
parts.push((zero() ? "T" : "F") + (notANumber() ? "T" : "F") + (!zero() ? "T" : "F") + (!notANumber() ? "T" : "F"));
let ticks = 0;
while (countdown()) { ticks++; }
left = 3;
let steps = 0;
for (let i = 0; countdown(); i++) { steps++; }
parts.push(`${ticks} ${steps}`);
parts.push(probe<string>(empty) + probe<string>(word) + probe<number>(zero) + probe<number>(notANumber) + probe<Named>(() => full) + probe<string | null>(() => maybeText("", true)));
const gone = !maybeText("s", true);
parts.push((gone ? "T" : "F") + (absent("s") ? "T" : "F") + (absent("") ? "T" : "F"));
const made = new Defaults();
parts.push(made.shown + (made.hidden ? "T" : "F") + made.pick("") + made.pick("p") + new Derived().marked);
console.log(parts.join(" | "));
