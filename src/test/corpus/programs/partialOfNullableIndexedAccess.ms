// @stdout: set set ro ro un un deep
interface D { id: string; tab: string }
interface E { id: string; size: int32 }
interface L { A: D | null; B: D; C: D | E }
interface R<PL, K extends keyof PL> { set: (p: Partial<PL[K]>) => string }
interface RO<PL, K extends keyof PL> { view: (p: Readonly<PL[K]>) => string }
interface Outer<PL, K extends keyof PL> { inner: R<PL, K> }

function mk<PL, K extends keyof PL>(tag: string): R<PL, K> {
	return { set: (p: Partial<PL[K]>): string => tag };
}
function mkRo<PL, K extends keyof PL>(): RO<PL, K> {
	return { view: (p: Readonly<PL[K]>): string => "ro" };
}
function mkOuter<PL, K extends keyof PL>(): Outer<PL, K> {
	const inner = mk<PL, K>("deep");
	return { inner: { set: (p: Partial<PL[K]>): string => inner.set(p) } };
}

function main(): void {
	const out: string[] = [];
	out.push(mk<L, "B">("set").set({ tab: "x" }));
	out.push(mk<L, "A">("set").set({ tab: "x" }));
	out.push(mkRo<L, "A">().view({ id: "i", tab: "t" }));
	out.push(mkRo<L, "B">().view({ id: "i", tab: "t" }));
	out.push(mk<L, "C">("un").set({ id: "u" }));
	out.push(mk<L, "C">("un").set({ size: 3 }));
	out.push(mkOuter<L, "A">().inner.set({ tab: "x" }));
	console.log(out.join(" "));
}
main();
