// @xfail(raiser): raiser prints an enum member as its ordinal (card 2026-09-25-raiser-enum-to-string-prints-the-number)
// @stdout: plain Home|explicit C B|field Home B|nested in Home B|concat Home Home|call Home Home
// @exit: 0
// note: an enum interpolated in a template is String(v), its member name, on every backend; JS used to print the ordinal.

enum Kind { Inherit, Home }
enum Val { A = 10, B = 20, C = 5 }
struct S { k: Kind; v: Val; }

const k: Kind = Kind.Home;
const s: S = { k: Kind.Home, v: Val.B };
const parts = [
	`plain ${k}`,
	`explicit ${Val.C} ${s.v}`,
	`field ${s.k} ${s.v}`,
	`nested ${`in ${k}`} ${`${s.v}`}`,
	"concat " + k + " " + s.k,
	`call ${String(k)} ${k.toString()}`,
];
console.log(parts.join("|"));
