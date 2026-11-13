// @stdout: named a|plain|no name|sw a|sw plain|or a|tag x|tag y|ok
// note: a match arm, a switch case or an `||` naming several members narrows to those members as the union they came
// from, so a test of the discriminant inside it narrows again (Haro's grouped request validation).
enum Kind { Plain, Named, Other }
struct Command = match (kind: Kind) {
	Kind.Plain => { host: int32 },
	Kind.Named => { host: int32, name: string | null },
	Kind.Other => {},
};
type Shape = { tag: "x"; x: int32 } | { tag: "y"; y: string } | { tag: "z" };

const out: string[] = [];

function viaArm(c: Command): string {
	match (c.kind) {
		Kind.Plain | Kind.Named => {
			if (c.kind == Kind.Named) {
				const name = c.name;
				return name === null ? "no name" : "named " + name;
			}
			return "plain";
		},
		Kind.Other => { return "other"; },
	}
}

function viaArmAnd(c: Command): boolean {
	match (c.kind) {
		Kind.Plain | Kind.Named => { return c.kind == Kind.Named && c.name !== null && c.name.length > 0; },
		Kind.Other => { return false; },
	}
}

function viaSwitch(c: Command): string {
	switch (c.kind) {
		case Kind.Plain:
		case Kind.Named:
			if (c.kind == Kind.Named) { return "sw " + (c.name ?? "-"); }
			return "sw plain";
		default: return "sw other";
	}
}

function viaOr(c: Command): string {
	if (c.kind == Kind.Plain || c.kind == Kind.Named) {
		if (c.kind == Kind.Named) { return "or " + (c.name ?? "-"); }
	}
	return "or -";
}

function viaTag(s: Shape): string {
	switch (s.tag) {
		case "x":
		case "y":
			if (s.tag == "x") return "tag x" + (s.x == 1 ? "" : "!");
			return "tag " + s.y;
		default: return "tag z";
	}
}

const named: Command = { kind: Kind.Named, host: 1, name: "a" };
const plain: Command = { kind: Kind.Plain, host: 2 };
const nameless: Command = { kind: Kind.Named, host: 3, name: null };
out.push(viaArm(named));
out.push(viaArm(plain));
out.push(viaArm(nameless));
out.push(viaSwitch(named));
out.push(viaSwitch(plain));
out.push(viaOr(named));
out.push(viaTag({ tag: "x", x: 1 }));
out.push(viaTag({ tag: "y", y: "y" }));
if (viaArmAnd(named) && !viaArmAnd(plain) && !viaArmAnd(nameless)) out.push("ok");
console.log(out.join("|"));
