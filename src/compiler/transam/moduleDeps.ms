// Trans-Am Module Dependencies — tracks import graph, BFS invalidation
//
// When file A imports file B, we record the edge. When B changes,
// getTransitiveDependents(B) returns all files transitively importing B
// so they can be marked RED.
//
// Arrays passed by pointer — bare T[] types.



// ===== Types =====

export interface TaDepEdge {
	importerFileId: number;
	importedFileId: number;
}

// ===== Module Dependency Graph =====

export interface TaModuleDepGraph {
	edges: TaDepEdge[];
}

export function createModuleDepGraph(): TaModuleDepGraph {
	return { edges: [] };
}

// ===== Edge Operations =====

function edgeExists(deps: TaModuleDepGraph, importer: number, imported: number): boolean {
	for (let i = 0; i < deps.edges.length; i = i + 1) {
		const e = deps.edges[i];
		if (e.importerFileId === importer && e.importedFileId === imported) return true;
	}
	return false;
}

export function recordModuleImport(deps: TaModuleDepGraph, importerFileId: number, importedFileId: number): void {
	if (edgeExists(deps, importerFileId, importedFileId)) return;
	const edge: TaDepEdge = { importerFileId, importedFileId };
	deps.edges.push(edge);
}

export function clearImportsFor(deps: TaModuleDepGraph, fileId: number): void {
	// Remove all edges where fileId is the importer
	let i = deps.edges.length;
	while (i > 0) {
		i = i - 1;
		if (deps.edges[i].importerFileId === fileId) {
			// Shift left and pop
			for (let j = i; j < deps.edges.length - 1; j = j + 1) {
				deps.edges[j] = deps.edges[j + 1];
			}
			deps.edges.pop();
		}
	}
}

// ===== Queries =====

export function getDirectImporters(deps: TaModuleDepGraph, fileId: number): number[] {
	const result: number[] = [];
	for (let i = 0; i < deps.edges.length; i = i + 1) {
		if (deps.edges[i].importedFileId === fileId) {
			result.push(deps.edges[i].importerFileId);
		}
	}
	return result;
}

// BFS: returns all files that transitively depend on the given file
export function getTransitiveDependents(deps: TaModuleDepGraph, fileId: number): number[] {
	const result: number[] = [];
	const queue: number[] = [];
	queue.push(fileId);

	while (queue.length > 0) {
		const current = queue.shift();
		const importers = getDirectImporters(deps, current);
		for (let i = 0; i < importers.length; i = i + 1) {
			const imp = importers[i];
			if (imp !== fileId && !numberListContains(result, imp)) {
				result.push(imp);
				queue.push(imp);
			}
		}
	}
	return result;
}

// ===== Forward Edge Queries =====

// Get all fileIds that `fileId` imports (forward edges)
export function getDirectImports(deps: TaModuleDepGraph, fileId: number): number[] {
	const result: number[] = [];
	for (let i = 0; i < deps.edges.length; i = i + 1) {
		if (deps.edges[i].importerFileId === fileId) {
			result.push(deps.edges[i].importedFileId);
		}
	}
	return result;
}

// Detect if importing `targetId` from `sourceId` creates a cycle.
// DFS from targetId following forward edges. Returns cycle path if reaches sourceId, [] otherwise.
export function detectCycle(deps: TaModuleDepGraph, sourceId: number, targetId: number): number[] {
	if (sourceId === targetId) return [sourceId];
	const visited: number[] = [];
	const stack: number[] = [];
	const parent: number[] = [];
	stack.push(targetId);
	parent.push(-1);

	while (stack.length > 0) {
		const current = stack.pop();
		const _parent = parent.pop();
		if (numberListContains(visited, current)) continue;
		visited.push(current);

		if (current === sourceId) {
			// Found cycle — reconstruct path
			const path: number[] = [sourceId, targetId];
			return path;
		}

		const imports = getDirectImports(deps, current);
		for (let i = 0; i < imports.length; i = i + 1) {
			if (!numberListContains(visited, imports[i])) {
				stack.push(imports[i]);
				parent.push(current);
			}
		}
	}
	return [];
}

// ===== Helpers =====

function numberListContains(list: number[], val: number): boolean {
	for (let i = 0; i < list.length; i = i + 1) {
		if (list[i] === val) return true;
	}
	return false;
}

// ===== Tests =====
test "empty graph" {
	const deps = createModuleDepGraph();
	expect(deps.edges.length === 0);
}

test "record import" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);
	expect(deps.edges.length === 1);
}

test "no duplicate edges" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);
	recordModuleImport(deps, 0, 1);
	expect(deps.edges.length === 1);
}

test "direct importers" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);  // 0 imports 1
	recordModuleImport(deps, 2, 1);  // 2 imports 1
	const imps = getDirectImporters(deps, 1);
	expect(imps.length === 2);
}

test "transitive: A->B->C" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);  // 0 imports 1
	recordModuleImport(deps, 1, 2);  // 1 imports 2
	const result = getTransitiveDependents(deps, 2);
	expect(result.length === 2);
	// Both 0 and 1 depend on 2
	expect(numberListContains(result, 0));
	expect(numberListContains(result, 1));
}

test "diamond: A->B, A->C, B->D, C->D" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);  // A imports B
	recordModuleImport(deps, 0, 2);  // A imports C
	recordModuleImport(deps, 1, 3);  // B imports D
	recordModuleImport(deps, 2, 3);  // C imports D
	const result = getTransitiveDependents(deps, 3);
	expect(result.length === 3);
	expect(numberListContains(result, 0));
	expect(numberListContains(result, 1));
	expect(numberListContains(result, 2));
}

test "cycle: A->B->A does not infinite loop" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);  // A imports B
	recordModuleImport(deps, 1, 0);  // B imports A
	const result = getTransitiveDependents(deps, 0);
	expect(result.length === 1);
	expect(numberListContains(result, 1));
}

test "no dependents" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);
	const result = getTransitiveDependents(deps, 0);
	expect(result.length === 0);
}

test "clear removes edges for file" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);
	recordModuleImport(deps, 0, 2);
	recordModuleImport(deps, 1, 2);
	clearImportsFor(deps, 0);
	expect(deps.edges.length === 1);
	// Only edge 1->2 remains
	expect(deps.edges[0].importerFileId === 1);
}
