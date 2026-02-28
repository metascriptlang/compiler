// Trans-Am Hash Utilities — djb2 string hashing, hash combinators
//
// Phase 1: simple hash for query key identification and file change detection.
// Phase 2: will add AST content-addressed hashing (hashNode).

import { TaQueryKey, TaQueryKind } from "./revision";
import { test, check, testGroup } from "std/testing";

// ===== String Hash (djb2) =====

export function taHashString(s: string): number {
	let hash = 5381;
	let i = 0;
	while (i < s.length) {
		hash = hash * 33 + s.charCodeAt(i);
		i = i + 1;
	}
	return hash;
}

// ===== Hash Combinators =====

export function taCombineHash(a: number, b: number): number {
	return a * 31 + b;
}

function enumToNum(kind: TaQueryKind): number {
	return match (kind) {
		TaQueryKind.FileText => 0,
		TaQueryKind.FileHash => 1,
		TaQueryKind.Parse => 2,
		TaQueryKind.TypeCheck => 3,
		TaQueryKind.Transform => 4,
		TaQueryKind.Analyze => 5,
		TaQueryKind.ModuleDeps => 6,
		_ => 0,
	};
}

export function taHashKey(key: TaQueryKey): number {
	return taCombineHash(enumToNum(key.queryKind) * 1000003, key.fileId);
}

// ===== Tests =====

testGroup("TaHashString", () => {
	test("empty string has known value", () => {
		const h = taHashString("");
		check(h === 5381);
	});
	test("same string same hash", () => {
		check(taHashString("hello") === taHashString("hello"));
	});
	test("different strings different hashes", () => {
		check(taHashString("abc") !== taHashString("xyz"));
	});
	test("single char", () => {
		const h = taHashString("a");
		check(h !== 5381);  // different from empty
		check(h !== 0);
	});
});

testGroup("TaHashCombine", () => {
	test("combine is deterministic", () => {
		check(taCombineHash(1, 2) === taCombineHash(1, 2));
	});
	test("order matters", () => {
		check(taCombineHash(1, 2) !== taCombineHash(2, 1));
	});
});

testGroup("TaHashKey", () => {
	test("different kinds produce different hashes", () => {
		const a: TaQueryKey = { queryKind: 0, fileId: 1 };
		const b: TaQueryKey = { queryKind: 1, fileId: 1 };
		check(taHashKey(a) !== taHashKey(b));
	});
	test("different fileIds produce different hashes", () => {
		const a: TaQueryKey = { queryKind: 0, fileId: 1 };
		const b: TaQueryKey = { queryKind: 0, fileId: 2 };
		check(taHashKey(a) !== taHashKey(b));
	});
});
