// @stdout: 1 1 1 1 1 5|y y
struct S { kind: "s"; n: int32 }
class C { kind: "r" = "r"; name: string = "x" }
type U = S | C;
struct Holder { u: U }

function readN(u: U): string {
	if (u.kind === "s") return u.n.toString();
	return "r";
}

function main(): void {
	let a: S = { kind: "s", n: 1 };
	const u: U = a;
	const y: U = u;
	const arr: U[] = [u];
	const h: Holder = { u };
	const g = h;
	a.n = 5;
	const c = new C();
	const hc: Holder = { u: c };
	const hc2 = hc;
	c.name = "y";
	const name = (u: U): string => u.kind === "r" ? u.name : "s";
	console.log(`${readN(u)} ${readN(y)} ${readN(arr[0])} ${readN(h.u)} ${readN(g.u)} ${a.n}|${name(hc.u)} ${name(hc2.u)}`);
}
main();
