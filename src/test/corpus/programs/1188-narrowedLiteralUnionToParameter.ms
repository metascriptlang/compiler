// @stdout: param=b,7
// @stdout: local=b,7
// @stdout: ret=b,7
// @stdout: num=2,x
// @stdout: twice=c,3
// @stdout: elem=b,7
// @stdout: float=2.5,x
function text(v: "b" | int32): string {
	return `${v}`;
}

function param(u: "a" | "b" | int32): string {
	if (u === "a") return "a";
	return text(u);
}

function local(u: "a" | "b" | int32): string {
	if (u === "a") return "a";
	const v: "b" | int32 = u;
	return `${v}`;
}

function narrowed(u: "a" | "b" | int32): "b" | int32 {
	if (u === "a") return 0;
	return u;
}

function num(u: 1 | 2 | "x"): string {
	if (u === 1) return "1";
	const v: 2 | "x" = u;
	return `${v}`;
}

function twice(u: "a" | "b" | "c" | int32): string {
	if (u === "a") return "a";
	if (u === "b") return "b";
	const v: "c" | int32 = u;
	return `${v}`;
}

function elem(u: "a" | "b" | int32): string {
	if (u === "a") return "a";
	const xs: ("b" | int32)[] = [u];
	return `${xs[0]}`;
}

function float(u: 1.5 | 2.5 | "x"): string {
	if (u === 1.5) return "1.5";
	const v: 2.5 | "x" = u;
	return `${v}`;
}

console.log(`param=${param("b")},${param(7)}`);
console.log(`local=${local("b")},${local(7)}`);
console.log(`ret=${narrowed("b")},${narrowed(7)}`);
console.log(`num=${num(2)},${num("x")}`);
console.log(`twice=${twice("c")},${twice(3)}`);
console.log(`elem=${elem("b")},${elem(7)}`);
console.log(`float=${float(2.5)},${float("x")}`);
