// @stdout: optional=1 2|1 null|
// @stdout: nullable=1 2|1 null|
// @stdout: float=1.5 2.5|
// @stdout: read=1 7|
// @stdout: string=s null|s t|
// @stdout: only=2|null|
// note: a conditional with a null arm passed to a generic parameter takes its type from its arms, so the type parameter binds to the arms' payload and the call compiles on every lane.
function g<T>(a: T, b?: T): string { return `${a} ${b}`; }
function k<T>(a: T, b: T | null): string { return `${a} ${b}`; }
function h<T>(b?: T): string { return `${b}`; }

function main(): void {
	const seven: number = 7;
	const yes: boolean = seven > 0;
	const no: boolean = seven < 0;
	console.log(`optional=${g(1, yes ? 2 : null)}|${g(1, no ? 2 : null)}|`);
	console.log(`nullable=${k(1, yes ? 2 : null)}|${k(1, yes ? null : 2)}|`);
	console.log(`float=${g(1.5, yes ? 2.5 : null)}|`);
	console.log(`read=${g(1, yes ? seven : null)}|`);
	console.log(`string=${g("s", yes ? null : "t")}|${g("s", no ? null : "t")}|`);
	console.log(`only=${h(yes ? 2 : null)}|${h(no ? 2 : null)}|`);
}

main();
