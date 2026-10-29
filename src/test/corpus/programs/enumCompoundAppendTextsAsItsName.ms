// @xfail(raiser): raiser prints an enum member as its ordinal (card 2026-09-25-raiser-enum-to-string-prints-the-number)
// @stdout: s=Home|field=Home|loop=Inherit1true,Inherit2true,|plus=Home|mixed=7 true
// @exit: 0
// note: `s += k` with an enum k appends the member name, as `s = s + k` does; C used to fail to build and JS appended the ordinal.

enum Kind { Inherit, Home }
class O { k: Kind = Kind.Home; }

const k: Kind = Kind.Home;
const o = new O();

let a = "s=";
a += k;

let b = "field=";
b += o.k;

let c = "loop=";
for (let i = 1; i <= 2; i += 1) {
	c += Kind.Inherit;
	c += i;
	c += true;
	c += ",";
}

let d = "plus=";
d = d + k;

let e = "mixed=";
e += 7;
e += " ";
e += true;

console.log([a, b, c, d, e].join("|"));
