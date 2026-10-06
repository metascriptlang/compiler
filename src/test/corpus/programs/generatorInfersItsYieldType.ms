// @stdout: 4,5,|a,bc,|2.5,|10,20,|1,2,|p,q,|x
// @xfail(raiser): the Raiser VM cannot compile a yield expression ('cannot compile node kind YieldExpr')
// note: a generator without a return annotation yields what its `yield`s yield, joined as returns are: a function with an early bare `return`, strings, an int and a float joined to float64, a function expression, a class method, a generic class's method, and one read before its body is checked. Same output on C and JS.
function* early(n: int32) { if (n < 0) return; yield n; yield n + 1; }
function* words() { yield "a"; yield "bc"; }
function* mixed(flag: boolean) { if (flag) yield 1; else yield 2.5; }
const pair = function* () { yield 10; yield 20; };

class G {
	*items() { yield 1; yield 2; }
}

class Bag<T> {
	items: T[] = [];
	*each() { for (const x of this.items) yield x; }
}

function firstOfLater() {
	let s = "";
	for (const v of later()) s += v;
	return s;
}
function* later() { yield "x"; }

const bag = new Bag<string>();
bag.items.push("p");
bag.items.push("q");
let out = "";
for (const x of early(4)) out += String(x) + ",";
for (const x of early(-1)) out += "never";
out += "|";
for (const w of words()) out += w + ",";
out += "|";
for (const m of mixed(false)) out += String(m) + ",";
out += "|";
for (const v of pair()) out += String(v) + ",";
out += "|";
for (const i of new G().items()) out += String(i) + ",";
out += "|";
for (const b of bag.each()) out += b + ",";
console.log(out + "|" + firstOfLater());
