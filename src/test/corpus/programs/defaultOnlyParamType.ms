// @stdout: 3 5 n y x q 3000000000 1.5 k3zk4zq3z
function run(n = 3): int32 {
	return n;
}
function flag(searching = false): string {
	return searching ? "y" : "n";
}
function str(s = "x"): string {
	return s;
}
function big(m = 3000000000, f = 1.5): string {
	return `${m} ${f}`;
}
class K {
	tag: string;
	constructor(t = "k") { this.tag = t; }
	go(n = 3, s = "z"): string { return `${this.tag}${n}${s}`; }
}
const k = new K();
console.log(`${run()} ${run(5)} ${flag()} ${flag(true)} ${str()} ${str("q")} ${big()} ${k.go() + k.go(4) + new K("q").go()}`);
