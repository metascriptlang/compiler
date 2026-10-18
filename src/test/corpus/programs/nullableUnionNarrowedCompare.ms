// @stdout: eq eq eq eq lt
// note: a value narrowed out of a nullable union compares as the member it was narrowed to, on a name and on a field path.

struct Slot { held: number | string | null; }

function afterNullCheck(v: number | string | null): string {
	if (v == null) return "null";
	if (typeof v === "string") return v;
	return v == 3 ? "eq" : "ne";
}

function byTypeof(v: number | boolean | null): string {
	if (typeof v === "number") return v == 3 ? "eq" : "ne";
	return "other";
}

function onField(s: Slot): string {
	if (typeof s.held === "number") return s.held == 3 ? "eq" : "ne";
	return "other";
}

function ordered(v: number | string | null): string {
	if (typeof v === "number") return v < 4 ? "lt" : "ge";
	return "other";
}

const slot: Slot = { held: 3 };
console.log(afterNullCheck(3) + " " + byTypeof(3) + " " + onField(slot) + " " + afterNullCheck(3.0) + " " + ordered(3));
