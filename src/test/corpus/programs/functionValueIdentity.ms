// @stdout: named=true true true false false true
// @stdout: closure=true false true false
// @stdout: array=0 1 true -1
// @stdout: generic=2 sets=1
// @stdout: optional=S T plain none
// @stdout: effects=true true false 3
function one(): int32 { return 1; }
function two(): int32 { return 2; }

const f: () => int32 = one;
const g: () => int32 = one;
const h: () => int32 = two;
console.log(`named=${f == one} ${one == f} ${f === g} ${f == h} ${f != one} ${f !== two}`);

function counter(start: int32): () => int32 {
	let n = start;
	return (): int32 => {
		n += 1;
		return n;
	};
}
const k1 = counter(0);
const k2 = k1;
const k3 = counter(0);
const k4 = (): int32 => 1;
console.log(`closure=${k1 === k2} ${k1 === k3} ${k1 !== k3} ${k4 === k1}`);

const fs: (() => int32)[] = [];
fs.push(one);
fs.push(k1);
console.log(`array=${fs.indexOf(one)} ${fs.indexOf(k2)} ${fs.includes(f)} ${fs.indexOf(two)}`);

class Signal<T> {
	value: T;
	sets: int32 = 0;
	constructor(v: T) { this.value = v; }
	set(n: T): void {
		if (this.value === n) return;
		this.value = n;
		this.sets += 1;
	}
}
const s = new Signal<() => int32>(one);
s.set(one);
s.set(two);
console.log(`generic=${s.value()} sets=${s.sets}`);

interface Props { title: string; }
interface Config { layout?: ((props: Props) => string) | null; }
function Stack(props: Props): string { return "stack"; }
function Tabs(props: Props): string { return "tabs"; }
function kind(c: Config): string {
	const layout = c.layout;
	if (layout == null) return "none";
	if (layout === Stack) return "S";
	if (layout === Tabs) return "T";
	return "plain";
}
const mine = (p: Props): string => "mine";
console.log(`optional=${kind({ layout: Stack })} ${kind({ layout: Tabs })} ${kind({ layout: mine })} ${kind({})}`);

let calls = 0;
function pick(): () => int32 {
	calls += 1;
	return one;
}
console.log(`effects=${pick() === f} ${f === pick()} ${pick() !== one} ${calls}`);
