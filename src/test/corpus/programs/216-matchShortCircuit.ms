// @stdout: seam2 a=false ea=0 b=true eb=0 c=30 ec=0 d=true ed=1 g=false
// note: Locks conditional evaluation of a match-EXPRESSION inside `&&`/`||` RHS
// and inside ternary arms. matchLower.hoistNestedMatch used a position-blind
// bottom-up walk (replaceInExpr), so a MatchExpr in a conditionally-evaluated
// position was hoisted OUT of its guard and its discriminant ran
// unconditionally. lowerMatch is a SHARED pass (runs on both backends), so C
// AND JS over-executed identically — byte-parity across lanes is BLIND here,
// which is why this program pins the effect counts via @stdout (the §3.6
// "every lane could be wrong in the same way" case). Covers: && RHS untaken
// (ea=0), || RHS untaken (eb=0), untaken ternary arm (ec=0), taken && RHS
// runs exactly once (ed=1), and the guard idiom `len>0 && match(arr[0])`
// where over-execution reads out of bounds (g=false, exit 0). Pre-fix: ea..ec
// counted 1..3, ed=4, and the guard shape crashed.

let eff: int32 = 0;
function bump(): int32 { eff = eff + 1; return 1; }

function main(): void {
	const flags: int32[] = [];
	const f: boolean = flags.length > 0;
	const t: boolean = flags.length == 0;

	// 1. && RHS, guard false → match must not run
	const a: boolean = f && (match (bump()) { 1 => true, _ => false });
	const ea: int32 = eff;

	// 2. || RHS, guard true → match must not run
	const b: boolean = t || (match (bump()) { 1 => true, _ => false });
	const eb: int32 = eff;

	// 3. untaken ternary arm → match must not run
	const c: int32 = f ? (match (bump()) { 1 => 10, _ => 20 }) : 30;
	const ec: int32 = eff;

	// 4. taken && RHS → match runs exactly once, value correct
	const d: boolean = t && (match (bump()) { 1 => true, _ => false });
	const ed: int32 = eff;

	// 5. guard idiom: disc is only valid under the guard (OOB if over-executed)
	const empty: int32[] = [];
	const g: boolean = empty.length > 0 && (match (empty[0]) { 0 => true, _ => false });

	console.log(`seam2 a=${a} ea=${ea} b=${b} eb=${eb} c=${c} ec=${ec} d=${d} ed=${ed} g=${g}`);
}
main();
