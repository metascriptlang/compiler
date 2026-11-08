// @stdout: num 3 | num 5 | store 7 | list 2 | num 8 base | store 7 base | view 4+1 | view 4+2 | count 6 | view 4+1

// A call through a constructor signature runs the implementation's branch that signature takes,
// with field initializers on every path and a super call that fills the parent's defaults.

class Store { bytes: number = 7; }

class Base {
	tag: string = "base";
	got: string;
	constructor();
	constructor(n: number);
	constructor(s: Store);
	constructor(xs: Readonly<number[]>);
	constructor(source: number | Store | Readonly<number[]> = 3) {
		if (typeof source == "number") this.got = `num ${source}`;
		else if (source instanceof Store) this.got = `store ${source.bytes}`;
		else this.got = `list ${source.length}`;
	}
}

class Kid extends Base {
	constructor(n: number);
	constructor(s: Store);
	constructor(source: number | Store) {
		if (typeof source == "number") super(source * 2);
		else super(source);
	}
}

class View {
	text: string;
	constructor(count: number);
	constructor(store: Store, offset: number);
	constructor(store: Store, offset: number, length: number);
	constructor(source: number | Store, offset: number = 0, length: number = -1) {
		if (typeof source == "number") this.text = `count ${source}`;
		else this.text = `view ${source.bytes - 3}+${length < 0 ? offset : length}`;
	}
}

class Bytes extends View {
	constructor(count: number);
	constructor(store: Store, offset: number);
	constructor(source: number | Store, offset: number = 0) {
		if (typeof source == "number") super(source * 2);
		else super(source, offset);
	}
}

const k1 = new Kid(4);
const k2 = new Kid(new Store());
const lines: string[] = [
	new Base().got, new Base(5).got, new Base(new Store()).got, new Base([1, 2]).got,
	`${k1.got} ${k1.tag}`, `${k2.got} ${k2.tag}`,
	new View(new Store(), 1).text, new View(new Store(), 9, 2).text, new Bytes(3).text, new Bytes(new Store(), 1).text,
];
console.log(lines.join(" | "));
