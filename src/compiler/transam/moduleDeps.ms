// Trans-Am Module Dependencies — tracks import graph, BFS invalidation
//
// When file A imports file B, we record the edge. When B changes,
// getTransitiveDependents(B) returns all files transitively importing B
// so they can be marked RED.
//
// DRC-safe: all arrays wrapped in interfaces.

import { test, check, testGroup } from "std/testing";

// ===== Types =====

export interface TaDepEdge {
	importerFileId: number;
	importedFileId: number;
}

export interface TaDepEdgeList {
	items: TaDepEdge[];
}

export interface TaNumberList {
	items: number[];
}

// ===== Module Dependency Graph =====

export interface TaModuleDepGraph {
	edges: TaDepEdgeList;
}

export function createModuleDepGraph(): TaModuleDepGraph {
	return { edges: { items: [] } };
}

// ===== Edge Operations =====

function edgeExists(deps: TaModuleDepGraph, importer: number, imported: number): boolean {
	for (let i = 0; i < deps.edges.items.length; i = i + 1) {
		const e = deps.edges.items[i];
		if (e.importerFileId === importer && e.importedFileId === imported) return true;
	}
	return false;
}

export function recordModuleImport(deps: TaModuleDepGraph, importerFileId: number, importedFileId: number): void {
	if (edgeExists(deps, importerFileId, importedFileId)) return;
	const edge: TaDepEdge = { importerFileId, importedFileId };
	deps.edges.items.push(edge);
}

export function clearImportsFor(deps: TaModuleDepGraph, fileId: number): void {
	// Remove all edges where fileId is the importer
	let i = deps.edges.items.length;
	while (i > 0) {
		i = i - 1;
		if (deps.edges.items[i].importerFileId === fileId) {
			// Shift left and pop
			for (let j = i; j < deps.edges.items.length - 1; j = j + 1) {
				deps.edges.items[j] = deps.edges.items[j + 1];
			}
			deps.edges.items.pop();
		}
	}
}

// ===== Queries =====

export function getDirectImporters(deps: TaModuleDepGraph, fileId: number): TaNumberList {
	const result: TaNumberList = { items: [] };
	for (let i = 0; i < deps.edges.items.length; i = i + 1) {
		if (deps.edges.items[i].importedFileId === fileId) {
			result.items.push(deps.edges.items[i].importerFileId);
		}
	}
	return result;
}

// BFS: returns all files that transitively depend on the given file
export function getTransitiveDependents(deps: TaModuleDepGraph, fileId: number): TaNumberList {
	const result: TaNumberList = { items: [] };
	const queue: TaNumberList = { items: [] };
	queue.items.push(fileId);

	while (queue.items.length > 0) {
		const current = queue.items.shift();
		const importers = getDirectImporters(deps, current);
		for (let i = 0; i < importers.items.length; i = i + 1) {
			const imp = importers.items[i];
			if (imp !== fileId && !numberListContains(result, imp)) {
				result.items.push(imp);
				queue.items.push(imp);
			}
		}
	}
	return result;
}

// ===== Helpers =====

function numberListContains(list: TaNumberList, val: number): boolean {
	for (let i = 0; i < list.items.length; i = i + 1) {
		if (list.items[i] === val) return true;
	}
	return false;
}

// ===== Tests =====

testGroup("TaModuleDepGraph Basics", () => {
	test("empty graph", () => {
		const deps = createModuleDepGraph();
		check(deps.edges.items.length === 0);
	});
	test("record import", () => {
		const deps = createModuleDepGraph();
		recordModuleImport(deps, 0, 1);
		check(deps.edges.items.length === 1);
	});
	test("no duplicate edges", () => {
		const deps = createModuleDepGraph();
		recordModuleImport(deps, 0, 1);
		recordModuleImport(deps, 0, 1);
		check(deps.edges.items.length === 1);
	});
	test("direct importers", () => {
		const deps = createModuleDepGraph();
		recordModuleImport(deps, 0, 1);  // 0 imports 1
		recordModuleImport(deps, 2, 1);  // 2 imports 1
		const imps = getDirectImporters(deps, 1);
		check(imps.items.length === 2);
	});
});

testGroup("TaModuleDepGraph BFS", () => {
	test("transitive: A->B->C", () => {
		const deps = createModuleDepGraph();
		recordModuleImport(deps, 0, 1);  // 0 imports 1
		recordModuleImport(deps, 1, 2);  // 1 imports 2
		const result = getTransitiveDependents(deps, 2);
		check(result.items.length === 2);
		// Both 0 and 1 depend on 2
		check(numberListContains(result, 0));
		check(numberListContains(result, 1));
	});
	test("diamond: A->B, A->C, B->D, C->D", () => {
		const deps = createModuleDepGraph();
		recordModuleImport(deps, 0, 1);  // A imports B
		recordModuleImport(deps, 0, 2);  // A imports C
		recordModuleImport(deps, 1, 3);  // B imports D
		recordModuleImport(deps, 2, 3);  // C imports D
		const result = getTransitiveDependents(deps, 3);
		check(result.items.length === 3);
		check(numberListContains(result, 0));
		check(numberListContains(result, 1));
		check(numberListContains(result, 2));
	});
	test("cycle: A->B->A does not infinite loop", () => {
		const deps = createModuleDepGraph();
		recordModuleImport(deps, 0, 1);  // A imports B
		recordModuleImport(deps, 1, 0);  // B imports A
		const result = getTransitiveDependents(deps, 0);
		check(result.items.length === 1);
		check(numberListContains(result, 1));
	});
	test("no dependents", () => {
		const deps = createModuleDepGraph();
		recordModuleImport(deps, 0, 1);
		const result = getTransitiveDependents(deps, 0);
		check(result.items.length === 0);
	});
});

testGroup("TaModuleDepGraph Clear", () => {
	test("clear removes edges for file", () => {
		const deps = createModuleDepGraph();
		recordModuleImport(deps, 0, 1);
		recordModuleImport(deps, 0, 2);
		recordModuleImport(deps, 1, 2);
		clearImportsFor(deps, 0);
		check(deps.edges.items.length === 1);
		// Only edge 1->2 remains
		check(deps.edges.items[0].importerFileId === 1);
	});
});
