// @stdout: a/a a/b n1/n1 calls=1 arm=n2/n2 skipped=2 and=true or=true loop=1 order=first@3|n4/n4 recv=14 ctor=n8,n8 method=n9:n9 arrow=n10/n10 triple=n11,n11,n11n11 closure=6
// note: a default value that reads an earlier parameter takes that argument, evaluated once, in a module other than the callee's: in a ternary arm and a short-circuit operand only when that branch runs, per iteration in a loop condition, after an earlier argument, for an extension receiver, a constructor, a method, an expression-bodied arrow, two defaults reading one argument, and a closure default that captures an earlier parameter.

import { label, triple, S, grow, Pt, Box, applyTo } from "./lib/label";

let calls = 0;
function next(): string {
	calls += 1;
	return "n" + calls.toString();
}
function makeS(): S {
	calls += 1;
	return { n: calls };
}
function first(): string {
	return "first@" + calls.toString();
}
function pair(a: string, b: string): string {
	return a + "|" + b;
}

const on = calls == 0;
const off = !on;
const parts: string[] = [];
parts.push(label("a"));
parts.push(label("a", "b"));
parts.push(label(next()));
parts.push("calls=" + calls.toString());
parts.push("arm=" + (on ? label(next()) : "no"));
parts.push("skipped=" + (off ? label(next()) : calls.toString()));
parts.push("and=" + (on && label(next()) == "n3/n3").toString());
parts.push("or=" + (off || label(next()) == "n4/n4").toString());
let rounds = 0;
while (label(next()) != "n6/n6") { rounds += 1; }
parts.push("loop=" + rounds.toString());
calls = 3;
parts.push("order=" + pair(first(), label(next())));
calls = 6;
parts.push("recv=" + makeS().grow().toString());
const p = new Pt(next());
parts.push("ctor=" + p.a + "," + p.b);
const box = new Box();
parts.push("method=" + box.show(next()));
const arrow = (): string => label(next());
parts.push("arrow=" + arrow());
parts.push("triple=" + triple(next()));
parts.push("closure=" + applyTo(3).toString());
console.log(parts.join(" "));
