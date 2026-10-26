// @stdout: abc abc ab2 abc abc abc abc abc | abc abc! ab-c abc abc abc
// @xfail(raiser): a `+=` on a string array element stops with an internal register error (inbox 2026-10-26-raiser-string-element-compound-append-fails-register-check)
// note: a string `+=`, `s = s + …` or template that appends to its own target reads the target before the right side runs, as TS does, when a call there writes it: a global, a self-concat, a field, an element (also when the call grows the array), a captured local, a field the callee appends to, a template and a chain, a method writing `this.body`, a function value. A plain local, a read-only neighbour and a method writing another field keep the in-place append and print the same.

let g = "ab";
function wg(): string { g = "Z"; return "c"; }
g += wg();

let g2 = "ab";
function wg2(): string { g2 = "Z"; return "c"; }
g2 = g2 + wg2();

let g3 = "ab";
function rg3(): string { return `${g3.length}`; }
g3 += rg3();

class Box { s: string = "ab"; }
const b = new Box();
function wb(): string { b.s = "Z"; return "c"; }
b.s += wb();

const arr: string[] = ["ab"];
function wa(): string { arr[0] = "Z"; return "c"; }
arr[0] += wa();

function captured(): string {
	let c = "ab";
	const w = (): string => { c = "Z"; return "c"; };
	c += w();
	return c;
}

function plainLocal(): string {
	let p = "ab";
	const w = (): string => "c";
	p += w();
	return p;
}

let g4 = "ab";
function wg4(): string { g4 += "Z"; return "c"; }
g4 += wg4();

const grown: string[] = ["ab"];
function grow(): string {
	for (let i = 0; i < 64; i += 1) grown.push("xxxxxxxxxxxxxxxx");
	grown[0] = "Z";
	return "c";
}
grown[0] += grow();

let g5 = "ab";
function wg5(): string { g5 = "Z"; return "c"; }
g5 = `${g5}${wg5()}!`;

let g6 = "ab";
function wg6(): string { g6 = "Z"; return "c"; }
g6 = g6 + "-" + wg6();

class Doc {
	body: string = "ab";
	other: string = "";
	part(): string { this.body = "Z"; return "c"; }
	side(): string { this.other = "Z"; return "c"; }
	build(): string {
		this.body += this.part();
		const first = this.body;
		this.body = "ab";
		this.body += this.side();
		return `${first} ${this.body}`;
	}
}

let g7 = "ab";
function viaValue(cb: () => string): string {
	g7 += cb();
	return g7;
}

console.log(`${g} ${g2} ${g3} ${b.s} ${arr[0]} ${captured()} ${plainLocal()} ${g4} | ${grown[0]} ${g5} ${g6} ${new Doc().build()} ${viaValue((): string => { g7 = "Z"; return "c"; })}`);
