// @stdout: 3|s|null|30
type Wire = number | string | null;

function same(v: Wire): number | string | null {
	return v as number | string | null;
}

function viaAlias(v: number | string | null): Wire {
	return v as Wire;
}

function text(v: number | string | null): string {
	if (v == null) return "null";
	if (typeof v === "string") return v;
	return v == 3 ? "3" : (v == 30 ? "30" : "?");
}

const n = viaAlias(30);
console.log(text(same(3)) + "|" + text(same("s")) + "|" + text(same(null)) + "|" + text(n));
