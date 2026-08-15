// @stdout: tailrec-match r=
// matchLower already expands a return-position match into arms that return
// directly, but it wraps them in a block — and transformStmt used to ignore
// BlockStmt, so the tail call inside was never rewritten to `continue`.

function loop(n: int64, acc: int64): int64 {
	return match (n) {
		0 => acc,
		_ => loop(n - 1, acc + 1),
	};
}

function grow(n: int64, s: string): string {
	return match (n) {
		0 => s,
		_ => grow(n - 1, s.slice(0, 1) + "y"),
	};
}

console.log("tailrec-match r=" + loop(5000000, 0).toString() + "-" + grow(200000, "y").length.toString());
