// @stdout: x y x2|1 two|said x:hi|said y:hi|a1m|bm|x y|ok
// note: a method every class of a union declares is called on the union; each member's own method runs,
// an override of a member's method still dispatches, and a result differing per member is their union.
const out: string[] = [];

class X {
	name(): string { return "x"; }
	size(): int32 { return 1; }
	say(word: string): void { out.push("said x:" + word); }
}
class Y {
	name(): string { return "y"; }
	size(): string { return "two"; }
	say(word: string): void { out.push("said y:" + word); }
}
class X2 extends X { name(): string { return "x2"; } }

class B {
	msg: string = "m";
	tag(): string { return "b"; }
}
class A1 extends B { tag(): string { return "a1"; } }
class A2 extends B { extra: int32 = 2; }

function nameOf(v: X | Y): string { return v.name(); }
function sizeText(v: X | Y): string {
	const s = v.size();
	return typeof s == "string" ? s : s.toString();
}
function tagOf(b: B): string {
	if (b instanceof A1 || b instanceof A2) return b.tag() + b.msg;
	return "-";
}

out.push(nameOf(new X()) + " " + nameOf(new Y()) + " " + nameOf(new X2()));
out.push(sizeText(new X()) + " " + sizeText(new Y()));
const items: (X | Y)[] = [new X(), new Y()];
for (const it of items) it.say("hi");
out.push(tagOf(new A1()));
out.push(tagOf(new A2()));
out.push(items.map((it: X | Y): string => it.name()).join(" "));
out.push("ok");
console.log(out.join("|"));
