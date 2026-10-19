export type Either<L, R> = match (ok: boolean) {
	true => { value: R },
	false => { error: L },
};

export function leftDiv(a: number, b: number): Either<string, number> {
	if (b == 0) return { ok: false, error: "left div0" };
	return { ok: true, value: a / b };
}

export function leftText(e: Either<string, number>): string {
	if (e.ok) return "value " + e.value;
	return e.error;
}
