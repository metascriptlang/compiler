// @stdout: pt:z nd:n 1 9
// note: a class field and a struct field of a union that mixes a value struct with a class or interface member release the held arm when the owner dies, and a copy of the struct owner copies the struct arm
struct Pt { kind: "pt"; x: int32; tag: string }
interface Nd { kind: "nd"; name: string }
type Mixed = Pt | Nd;

class Holder { m: Mixed = { kind: "pt", x: 0, tag: "z" } as Pt; }
struct Wrap { m: Mixed }

function show(m: Mixed): string {
	if (m.kind === "nd") return "nd:" + m.name;
	return "pt:" + m.tag;
}

function main(): void {
	const h = new Holder();
	const n = new Holder();
	n.m = { kind: "nd", name: "n" } as Nd;
	const w: Wrap = { m: { kind: "pt", x: 1, tag: "z" } as Pt };
	let c = w;
	let cm = c.m as Pt;
	cm.x = 9;
	const wp = w.m as Pt;
	console.log(`${show(h.m)} ${show(n.m)} ${wp.x} ${cm.x}`);
}
main();
