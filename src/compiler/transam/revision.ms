// Trans-Am Revision — foundation enums, query key, revision tracking
//
// All other transam/ files import from here.
// Ta-prefixed to avoid C namespace collision.

import { check } from "std/testing";

// ===== Query Kind — what type of computation is cached =====

export enum TaQueryKind {
	FileText,     // input: raw source text
	FileHash,     // input: content hash
	Parse,        // derived: source -> AST
	TypeCheck,    // derived: AST -> CheckerContext
	Transform,    // derived: typed AST -> transformed AST
	Analyze,      // derived: transformed -> DRC-injected AST
	ModuleDeps,   // derived: parse -> import list
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

export interface TaRevision {
	value: number;
}

export function createRevision(): TaRevision {
	return { value: 0 };
}

export function incrementRevision(rev: TaRevision): void {
	rev.value = rev.value + 1;
}

// ===== Query Key — uniquely identifies a cached query =====

export interface TaQueryKey {
	queryKind: TaQueryKind;
	fileId: number;        // sequential file ID (not content hash in Phase 1)
}

export function createQueryKey(kind: TaQueryKind, fileId: number): TaQueryKey {
	return { queryKind: kind, fileId };
}

export function queryKeysEqual(a: TaQueryKey, b: TaQueryKey): boolean {
	return a.queryKind === b.queryKind && a.fileId === b.fileId;
}

// ===== Tests =====
test "init starts at zero" {
	const rev = createRevision();
	check(rev.value === 0);
}

test "increment advances" {
	const rev = createRevision();
	incrementRevision(rev);
	check(rev.value === 1);
	incrementRevision(rev);
	check(rev.value === 2);
}

test "create stores kind and fileId" {
	const key = createQueryKey(TaQueryKind.Parse, 42);
	check(key.queryKind === TaQueryKind.Parse);
	check(key.fileId === 42);
}

test "equal keys match" {
	const a = createQueryKey(TaQueryKind.Parse, 1);
	const b = createQueryKey(TaQueryKind.Parse, 1);
	check(queryKeysEqual(a, b));
}

test "different kind does not match" {
	const a = createQueryKey(TaQueryKind.Parse, 1);
	const b = createQueryKey(TaQueryKind.TypeCheck, 1);
	check(!queryKeysEqual(a, b));
}

test "different fileId does not match" {
	const a = createQueryKey(TaQueryKind.Parse, 1);
	const b = createQueryKey(TaQueryKind.Parse, 2);
	check(!queryKeysEqual(a, b));
}

test "query kinds are distinct" {
	check(TaQueryKind.FileText !== TaQueryKind.Parse);
	check(TaQueryKind.Parse !== TaQueryKind.TypeCheck);
	check(TaQueryKind.TypeCheck !== TaQueryKind.Transform);
	check(TaQueryKind.Transform !== TaQueryKind.Analyze);
}

test "query states are distinct" {
	check(TaQueryState.Green !== TaQueryState.Red);
	check(TaQueryState.Red !== TaQueryState.Yellow);
}

test "durability levels are distinct" {
	check(TaDurability.Low !== TaDurability.Medium);
	check(TaDurability.Medium !== TaDurability.High);
}
