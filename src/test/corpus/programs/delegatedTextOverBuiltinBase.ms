// @stdout: 5 5 5 5 | ab ab ab | 1.5 true 7 | 300
// note: a distinct over a number, a string or a boolean delegates toString to the text its base already has, through a template, String(), .toString(), concatenation and a call, and a distinct of such a distinct and a generic distinct delegate the same way. Same output on every backend.
type Small = distinct int8;
@delegate function toString(this s: Small): string;
type Name = distinct string;
@delegate function toString(this n: Name): string;
type Ratio = distinct float64;
@delegate function toString(this r: Ratio): string;
type Flag = distinct boolean;
@delegate function toString(this f: Flag): string;
type Tiny = distinct Small;
@delegate function toString(this t: Tiny): string;
type Count<T> = distinct int32;
@delegate function toString<T>(this c: Count<T>): string;

const s = 5 as Small;
const n = "ab" as Name;
const r = 1.5 as Ratio;
const f = true as Flag;
const t = (7 as Small) as Tiny;
const c = 300 as Count<string>;
const nums = `${s} ${String(s)} ${s.toString()} ` + s;
const names = `${n} ${String(n)} ` + n.toString();
console.log(`${nums} | ${names} | ${r} ${f} ${t} | ${toString(c)}`);
