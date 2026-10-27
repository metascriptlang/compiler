// @stdout: 1 2
// @stdout: 3 named
// @stdout: 5 6 7
// note: a struct local declared without an initializer in a function whose body can raise is a zero value the callee fills through `out`: a plain struct, a struct holding a string, and one filled twice in a loop
struct Pt { x: int32; y: int32; }
struct Named { id: int32; name: string; }

function setPt(out p: Pt, x: int32, y: int32): void { p = { x, y }; }
function setNamed(out n: Named): void { n = { id: 3, name: "named" }; }

function plain(): string {
	let p: Pt;
	setPt(out p, 1, 2);
	return `${p.x} ${p.y}`;
}

function holding(): string {
	let n: Named;
	setNamed(out n);
	return `${n.id} ${n.name}`;
}

function looped(): string {
	let p: Pt;
	let parts = "";
	for (let i: int32 = 5; i <= 7; i++) {
		setPt(out p, i, 0);
		parts = parts + (i == 5 ? "" : " ") + p.x.toString();
	}
	return parts;
}

console.log(plain());
console.log(holding());
console.log(looped());
