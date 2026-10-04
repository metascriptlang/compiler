// @stdout: center center N top stretch | 6 1
type Align = "auto" | "center" | "stretch";
type Edge = "top" | "bottom";

function pa(k: int32): Align | null {
	if (k == 1) return "center";
	return null;
}

function pe(k: int32): Edge {
	return k == 1 ? "top" : "bottom";
}

function pick(k: int32): Align {
	return k == 1 ? "stretch" : "auto";
}

function run(): void {
	const a = pa(1);
	const b = pa(2);
	const c = a != null ? a : "N";
	const q = a ?? "N";
	const r = b ?? "N";
	const j = b != null ? b : pe(1);
	const s = a != null ? pick(1) : pick(2);
	const keep: Align = s;
	console.log(`${c} ${q} ${r} ${j} ${keep} | ${q.length} ${r.length}`);
}

run();
