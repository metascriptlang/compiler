// Trans-Am Revision — foundation enums, query key, revision tracking
//
// All other transam/ files import from here.
// Ta-prefixed to avoid C namespace collision.



// ===== Query Kind — what type of computation is cached =====

export enum TaQueryKind {
	FileText,     // input: raw source text
	FileHash,     // input: content hash
	Preprocess,   // derived: raw text -> preprocessed source (.h translation, .h import inlining)
	Parse,        // derived: source -> AST
	TypeCheck,    // derived: AST -> CheckerContext
	Transform,    // derived: typed AST -> transformed AST
	Analyze,      // derived: transformed -> DRC-injected AST
	ModuleDeps,   // derived: parse -> import list
	Lower,
}

// ===== Query State — red-green verification state =====

export enum TaQueryState {
	Green,   // verified current this revision
	Red,     // potentially stale, needs verification
	Yellow,  // currently being verified (cycle detection)
}

// ===== Durability — how stable is this input? =====

export enum TaDurability {
	Low,     // user source (src/*.ms) — changes frequently
	Medium,  // config files
	High,    // std library — skip verification
}

// ===== Revision — monotonically increasing counter =====

export class TaRevision {
	value: int32;
}

export function createRevision(): TaRevision {
	return { value: 0 };
}

export const TA_REVISION_MAX: int32 = 2147483647;

export function nextRevision(rev: TaRevision): int32 {
	if (rev.value >= TA_REVISION_MAX) throw new Error("internal: Trans-Am revision exhausted at " + rev.value);
	return rev.value + 1;
}

export function incrementRevision(rev: TaRevision): void {
	rev.value = nextRevision(rev);
}

// ===== Query Key — uniquely identifies a cached query =====

export struct TaQueryKey {
	queryKind: TaQueryKind;
	fileId: int32;         // sequential file ID (not content hash in Phase 1)
}

export function createQueryKey(kind: TaQueryKind, fileId: int32): TaQueryKey {
	return { queryKind: kind, fileId };
}

export function queryKeysEqual(a: TaQueryKey, b: TaQueryKey): boolean {
	return a.queryKind == b.queryKind && a.fileId == b.fileId;
}

// ===== Tests =====
test "init starts at zero" {
	const rev = createRevision();
	assert rev.value == 0;
}

test "increment advances" {
	const rev = createRevision();
	incrementRevision(rev);
	assert rev.value == 1;
	incrementRevision(rev);
	assert rev.value == 2;
}

test "create stores kind and fileId" {
	const key = createQueryKey(TaQueryKind.Parse, 42);
	assert key.queryKind == TaQueryKind.Parse;
	assert key.fileId == 42;
}

test "equal keys match" {
	const a = createQueryKey(TaQueryKind.Parse, 1);
	const b = createQueryKey(TaQueryKind.Parse, 1);
	assert queryKeysEqual(a, b);
}

test "different kind does not match" {
	const a = createQueryKey(TaQueryKind.Parse, 1);
	const b = createQueryKey(TaQueryKind.TypeCheck, 1);
	assert !queryKeysEqual(a, b);
}

test "different fileId does not match" {
	const a = createQueryKey(TaQueryKind.Parse, 1);
	const b = createQueryKey(TaQueryKind.Parse, 2);
	assert !queryKeysEqual(a, b);
}

test "query kinds are distinct" {
	assert TaQueryKind.FileText != TaQueryKind.Parse;
	assert TaQueryKind.Parse != TaQueryKind.TypeCheck;
	assert TaQueryKind.TypeCheck != TaQueryKind.Transform;
	assert TaQueryKind.Transform != TaQueryKind.Analyze;
}

test "query states are distinct" {
	assert TaQueryState.Green != TaQueryState.Red;
	assert TaQueryState.Red != TaQueryState.Yellow;
}

test "durability levels are distinct" {
	assert TaDurability.Low != TaDurability.Medium;
	assert TaDurability.Medium != TaDurability.High;
}

test "the revision refuses to pass its maximum" {
	const rev: TaRevision = { value: TA_REVISION_MAX - 1 };
	incrementRevision(rev);
	assert rev.value == TA_REVISION_MAX;
	let refused = false;
	try { incrementRevision(rev); } catch (e) { refused = true; }
	assert refused;
	assert rev.value == TA_REVISION_MAX;
}
