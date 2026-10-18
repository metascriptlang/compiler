// @stdout: s n s n l b S N
// note: a call into a set of overload signatures picks a signature, and the body is a candidate only when no signature takes the call; a body that takes a union no longer ties with the signature of one of its members, through a named import, a namespace import, in the declaring module and as an extension.
import { fmt } from "./lib";
import * as L from "./lib";

function local(s: string): string;
function local(b: boolean): string;
function local(x: string | boolean): string {
	if (typeof x == "string") return "l";
	return "b";
}

const v: string | int32 = 3;
console.log(`${fmt("a")} ${fmt(2 as int32)} ${L.fmt("a")} ${L.fmt(v)} ${local("x")} ${local(true)} ${"a".show()} ${(4 as int32).show()}`);
