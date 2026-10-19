export type Either<L, R> = match (ok: boolean) {
	true => { value: R },
	false => { error: L },
};

export function rightDiv(a: number, b: number): Either<string, number> {
	if (b == 0) return { ok: false, error: "right div0" };
	return { ok: true, value: a / b };
}

export function rightPair(a: number): Either<number, string> {
	if (a == 0) return { ok: false, error: 0 };
	return { ok: true, value: "n" + a };
}

export function rightText(e: Either<string, number>): string {
	if (e.ok) return "value " + e.value;
	return e.error;
}
