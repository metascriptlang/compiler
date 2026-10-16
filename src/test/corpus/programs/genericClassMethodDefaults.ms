// @stdout: 111|3 8|on off
// note: an omitted argument of a generic class's method takes the parameter's default, whether
// the default is typed by the class's type parameter, by a plain type or by a generic interface.
interface Opts<C> {
	flag?: boolean | null;
	label?: ((value: C) => string | null) | null;
}

class Gen<P> {
	count: int32 = 0;
	go(name: string, params: P | null = null): void { this.count += 1; }
	add(by: int32 = 1): int32 { this.count += by; return this.count; }
	make(options: Opts<P> = {}): string {
		const flag = options.flag ?? true;
		return flag ? "on" : "off";
	}
}

class Plain {
	count: int32 = 0;
	go(name: string, params: string | null = null): void { this.count += 1; }
}

function make<P>(): Gen<P> { return new Gen<P>(); }

const g = new Gen<int32>();
g.go("a");
const p = new Plain();
p.go("a");
const m = make<string>();
m.go("b");
console.log(g.count.toString() + p.count.toString() + m.count.toString());

const h = new Gen<string>();
h.go("a");
h.go("b", "x");
console.log(h.add().toString() + " " + h.add(5).toString());
console.log(g.make() + " " + g.make({ flag: false }));
