// Parity program — a value struct allocated through Ref<S> inside a function links and
// runs: the cell's TypeInfo names the struct's destroy hook, so the hook stays reachable
// whether the struct owns a managed field or none.
//
// @stdout: 13|14|ok-7
// @exit: 0

struct Plain { n: int32; }
struct Named { label: string; n: int32; }

function plain(): int32 {
	const a: Ref<Plain> = { n: 13 };
	return a.n;
}

function named(): string {
	const b: Ref<Named> = { label: "ok", n: 7 };
	return `${b.label}-${b.n}`;
}

console.log(`${plain()}|${plain() + 1}|${named()}`);
