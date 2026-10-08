// @stdout: true|false|string s|true
// @stdout: bool|true|true
// note: `as` from a union holding boolean to boolean literal types converts when the held boolean is the literal: into `true | null`, `false | string`, a lone `true`, and `true | false | int32`. A held boolean the literal does not match stops (sibling: unionBooleanLiteralStops). Same output on C, JS and the Raiser.
function flag(c: int32): boolean | string { return c == 0 ? true : c == 1 ? false : "s"; }
function showT(t: true | null): string { return t == null ? "null" : "true"; }
function showF(t: false | string): string { return typeof t === "string" ? "string " + t : "false"; }
console.log(showT(flag(0) as true | null) + "|" + showF(flag(1) as false | string) + "|" + showF(flag(2) as false | string) + "|" + String(flag(0) as true));
function isTrue(t: true | false | int32): string { const k = t as true | false | int32; return typeof k === "number" ? "int32" : "bool"; }
const tf0 = flag(0) as true | false | int32;
const tf1 = flag(1) as true | false | int32;
console.log(isTrue(tf0) + "|" + String((tf0 as true) == true) + "|" + String((tf1 as false) == false));
