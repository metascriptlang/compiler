// @stdout: p|a|a|b|c
type Acc<T> = distinct (() => T);
type Pln<T> = (() => T);

function apply<P>(Comp: (props: P) => string, props: P): string { return Comp(props); }
function plain<T>(p: { children: (item: T) => string }): string { return "p"; }
function viaAcc<T>(p: { children: (item: Acc<T>) => string }): string { return "a"; }
function viaPln<T>(p: { children: (item: Pln<T>) => string }): string { return "b"; }
function viaArr<T>(p: { children: (item: T[]) => string }): string { return "c"; }

const explicit = viaAcc<number>({ children: (n: Acc<number>): string => "x" });
console.log([
	apply(plain, { children: (n: number): string => "1" }),
	apply(viaAcc, { children: (n: Acc<number>): string => "2" }),
	explicit,
	apply(viaPln, { children: (n: Pln<number>): string => "3" }),
	apply(viaArr, { children: (n: number[]): string => "4" }),
].join("|"));
