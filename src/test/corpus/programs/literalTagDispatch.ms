// @stdout: a1 b2 c3 | ab ab c | x:1 y:2 | t f | 7 9 | c3 a1 | 0 2 | n0 n1 n2 | 4
// note: a compare or a switch over a union's literal discriminant (string, number, boolean) picks the member the literal names, inside a branch that already narrowed the union, through a field, an element and a call result.

type Tri = { k: "a"; n: int32 } | { k: "b"; n: int32 } | { k: "c"; n: int32 };

function tri(t: Tri): string {
	if (t.k !== "a") {
		if (t.k === "c") return `c${t.n}`;
		return `b${t.n}`;
	}
	return `a${t.n}`;
}

function grouped(t: Tri): string {
	switch (t.k) {
		case "a":
		case "b":
			return "ab";
		default:
			return t.k;
	}
}

type Num = { tag: 7; x: int32 } | { tag: -2; y: int32 };

function num(v: Num): string {
	if (-2 == v.tag) return `y:${v.y}`;
	return `x:${v.x}`;
}

type Flag = { on: true; n: int32 } | { on: false };

function flag(f: Flag): string {
	return f.on === true ? "t" : "f";
}

class Holder {
	t: Tri = { k: "c", n: 9 };
}

function make(i: int32): Tri {
	if (i == 0) return { k: "a", n: 1 };
	return { k: "c", n: 3 };
}

const tris: Tri[] = [{ k: "a", n: 1 }, { k: "b", n: 2 }, { k: "c", n: 3 }];
const h = new Holder();
const one: Tri = { k: "b", n: 4 };
let picked = 0;
for (let i = 0; i < tris.length; i += 1) if (tris[i].k === "c") picked = i;
let count = 0;
for (const t of tris) {
	switch (t.k) {
		case "c": count += 2; break;
		case "a": break;
		case "b": break;
	}
}
const kinds: string[] = [];
for (const t of tris) kinds.push(t.k == "a" ? "n0" : t.k != "c" ? "n1" : "n2");
console.log(`${tris.map(tri).join(" ")} | ${tris.map(grouped).join(" ")} | ${num({ tag: 7, x: 1 })} ${num({ tag: -2, y: 2 })} | ${flag({ on: true, n: 1 })} ${flag({ on: false })} | ${h.t.k === "c" ? 7 : 0} ${h.t.k == "c" ? h.t.n : 0} | ${tri(make(1))} ${tri(make(0))} | ${picked - 2} ${count} | ${kinds.join(" ")} | ${one.k === "b" ? one.n : 0}`);
