// note: a constructor with defaults and a class with only field initializers, on every lane including the Raiser VM
class Defaults {
	a: number;
	b: string;
	constructor(a: number = 5, b: string = "dflt") { this.a = a; this.b = b; }
}
class Fields {
	x: number = 3;
	y: string = "yy";
}
const d1 = new Defaults();
const d2 = new Defaults(9);
console.log("defaults", d1.a, d1.b, d2.a, d2.b);
const f = new Fields();
console.log("fields", f.x, f.y);
