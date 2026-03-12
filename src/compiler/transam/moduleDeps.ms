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
	reverseAdj: number[][];  // importedFileId → [importerFileId, ...] for O(1) reverse lookup
	registeredAt: number[];  // fileId → revision when exports registered (-1 = never)
}

export function createModuleDepGraph(): TaModuleDepGraph {
	return { edges: [], reverseAdj: [], registeredAt: [] };
}

// ===== Export Registration Revision =====

function ensureRegisteredAtCapacity(deps: TaModuleDepGraph, fileId: number): void {
	while (deps.registeredAt.length <= fileId) {
		deps.registeredAt.push(-1);
	}
}

export function getRegisteredAt(deps: TaModuleDepGraph, fileId: number): number {
	if (fileId < 0 || fileId >= deps.registeredAt.length) return -1;
	return deps.registeredAt[fileId];
}

export function setRegisteredAt(deps: TaModuleDepGraph, fileId: number, rev: number): void {
	ensureRegisteredAtCapacity(deps, fileId);
	deps.registeredAt[fileId] = rev;
}

export function resetRegisteredAt(deps: TaModuleDepGraph, fileId: number): void {
	if (fileId >= 0 && fileId < deps.registeredAt.length) {
		deps.registeredAt[fileId] = -1;
	}
}

// ===== Edge Operations =====

function edgeExists(deps: TaModuleDepGraph, importer: number, imported: number): boolean {
	// Use reverse index for O(degree) check instead of O(E) edge scan
	if (imported >= deps.reverseAdj.length) return false;
	const rev = deps.reverseAdj[imported];
	for (let i = 0; i < rev.length; i = i + 1) {
		if (rev[i] === importer) return true;
	}
	return false;
}

export function recordModuleImport(deps: TaModuleDepGraph, importerFileId: number, importedFileId: number): void {
	if (edgeExists(deps, importerFileId, importedFileId)) return;
	const edge: TaDepEdge = { importerFileId, importedFileId };
	deps.edges.push(edge);
	// Maintain reverse adjacency index
	while (deps.reverseAdj.length <= importedFileId) {
		const empty: number[] = [];
		deps.reverseAdj.push(empty);
	}
	deps.reverseAdj[importedFileId].push(importerFileId);
}

export function clearImportsFor(deps: TaModuleDepGraph, fileId: number): void {
	// Remove all edges where fileId is the importer + update reverse index
	let i = deps.edges.length;
	while (i > 0) {
		i = i - 1;
		if (deps.edges[i].importerFileId === fileId) {
			const imported = deps.edges[i].importedFileId;
			// Remove from reverse adjacency
			if (imported < deps.reverseAdj.length) {
				const rev = deps.reverseAdj[imported];
				let ri = rev.length;
				while (ri > 0) {
					ri = ri - 1;
					if (rev[ri] === fileId) {
						for (let rj = ri; rj < rev.length - 1; rj = rj + 1) {
							rev[rj] = rev[rj + 1];
						}
						rev.pop();
						break;
					}
				}
			}
			// Shift left and pop forward edge
			for (let j = i; j < deps.edges.length - 1; j = j + 1) {
				deps.edges[j] = deps.edges[j + 1];
			}
			deps.edges.pop();
		}
	}
}

// ===== Queries =====

export function getDirectImporters(deps: TaModuleDepGraph, fileId: number): number[] {
	if (fileId < 0 || fileId >= deps.reverseAdj.length) return [];
	const rev = deps.reverseAdj[fileId];
	const result: number[] = [];
	for (let i = 0; i < rev.length; i = i + 1) {
		result.push(rev[i]);
	}
	return result;
}

// BFS: returns all files that transitively depend on the given file
export function getTransitiveDependents(deps: TaModuleDepGraph, fileId: number): number[] {
	const result: number[] = [];
	const queue: number[] = [];
	// O(1) visited check via boolean[] indexed by fileId
	const visited: boolean[] = [];
	let maxId = deps.reverseAdj.length;
	while (visited.length < maxId) {
		visited.push(false);
	}
	// Ensure fileId itself fits
	while (visited.length <= fileId) {
		visited.push(false);
	}
	visited[fileId] = true;  // don't include seed in results
	queue.push(fileId);

	while (queue.length > 0) {
		const current = queue.shift();
		const importers = getDirectImporters(deps, current);
		for (const imp of importers) {
			// Grow visited if needed (importerFileId may exceed reverseAdj.length)
			while (visited.length <= imp) {
				visited.push(false);
			}
			if (!visited[imp]) {
				visited[imp] = true;
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
	for (const edge of deps.edges) {
		if (edge.importerFileId === fileId) {
			result.push(edge.importedFileId);
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
	assert deps.edges.length === 0;
}

test "record import" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);
	assert deps.edges.length === 1;
}

test "no duplicate edges" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);
	recordModuleImport(deps, 0, 1);
	assert deps.edges.length === 1;
}

test "direct importers" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);  // 0 imports 1
	recordModuleImport(deps, 2, 1);  // 2 imports 1
	const imps = getDirectImporters(deps, 1);
	assert imps.length === 2;
}

test "transitive: A->B->C" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);  // 0 imports 1
	recordModuleImport(deps, 1, 2);  // 1 imports 2
	const result = getTransitiveDependents(deps, 2);
	assert result.length === 2;
	// Both 0 and 1 depend on 2
	assert numberListContains(result, 0);
	assert numberListContains(result, 1);
}

test "diamond: A->B, A->C, B->D, C->D" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);  // A imports B
	recordModuleImport(deps, 0, 2);  // A imports C
	recordModuleImport(deps, 1, 3);  // B imports D
	recordModuleImport(deps, 2, 3);  // C imports D
	const result = getTransitiveDependents(deps, 3);
	assert result.length === 3;
	assert numberListContains(result, 0);
	assert numberListContains(result, 1);
	assert numberListContains(result, 2);
}

test "cycle: A->B->A does not infinite loop" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);  // A imports B
	recordModuleImport(deps, 1, 0);  // B imports A
	const result = getTransitiveDependents(deps, 0);
	assert result.length === 1;
	assert numberListContains(result, 1);
}

test "no dependents" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);
	const result = getTransitiveDependents(deps, 0);
	assert result.length === 0;
}

test "clear removes edges for file" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);
	recordModuleImport(deps, 0, 2);
	recordModuleImport(deps, 1, 2);
	clearImportsFor(deps, 0);
	assert deps.edges.length === 1;
	// Only edge 1->2 remains
	assert deps.edges[0].importerFileId === 1;
}

test "reverse index after clear" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);
	recordModuleImport(deps, 2, 1);
	recordModuleImport(deps, 0, 3);
	// reverseAdj[1] should have [0, 2]
	let imps = getDirectImporters(deps, 1);
	assert imps.length === 2;
	// Clear file 0's imports
	clearImportsFor(deps, 0);
	// reverseAdj[1] should now only have [2]
	imps = getDirectImporters(deps, 1);
	assert imps.length === 1;
	assert imps[0] === 2;
	// reverseAdj[3] should be empty (0 was the only importer)
	imps = getDirectImporters(deps, 3);
	assert imps.length === 0;
}

test "registeredAt tracking" {
	const deps = createModuleDepGraph();
	assert getRegisteredAt(deps, 0) === -1;
	setRegisteredAt(deps, 0, 5);
	assert getRegisteredAt(deps, 0) === 5;
	resetRegisteredAt(deps, 0);
	assert getRegisteredAt(deps, 0) === -1;
}
