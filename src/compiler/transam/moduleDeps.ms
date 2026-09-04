// Trans-Am Module Dependencies — tracks import graph, BFS invalidation
//
// When file A imports file B, we record the edge. When B changes,
// getTransitiveDependents(B) returns all files transitively importing B
// so they can be marked RED.
//
// Arrays passed by pointer — bare T[] types.



// ===== Types =====

export interface TaDepEdge {
	importerFileId: int32;
	importedFileId: int32;
}

// ===== Module Dependency Graph =====

export class TaModuleDepGraph {
	edges: TaDepEdge[];
	reverseAdj: int32[][];  // importedFileId → [importerFileId, ...] for O(1) reverse lookup
	registeredAt: int32[];  // fileId → revision when exports registered (-1 = never)
}

export function createModuleDepGraph(): TaModuleDepGraph {
	return { edges: [], reverseAdj: [], registeredAt: [] };
}

// ===== Export Registration Revision =====

function ensureRegisteredAtCapacity(deps: TaModuleDepGraph, fileId: int32): void {
	while (deps.registeredAt.length <= fileId) {
		deps.registeredAt.push(-1);
	}
}

export function getRegisteredAt(deps: TaModuleDepGraph, fileId: int32): int32 {
	if (fileId < 0 || fileId >= deps.registeredAt.length) return -1;
	return deps.registeredAt[fileId];
}

export function setRegisteredAt(deps: TaModuleDepGraph, fileId: int32, rev: int32): void {
	ensureRegisteredAtCapacity(deps, fileId);
	deps.registeredAt[fileId] = rev;
}

export function resetRegisteredAt(deps: TaModuleDepGraph, fileId: int32): void {
	if (fileId >= 0 && fileId < deps.registeredAt.length) {
		deps.registeredAt[fileId] = -1;
	}
}

// ===== Edge Operations =====

function edgeExists(deps: TaModuleDepGraph, importer: int32, imported: int32): boolean {
	// Use reverse index for O(degree) check instead of O(E) edge scan
	if (imported >= deps.reverseAdj.length) return false;
	const rev = deps.reverseAdj[imported];
	for (let i = 0; i < rev.length; i = i + 1) {
		if (rev[i] === importer) return true;
	}
	return false;
}

export function recordModuleImport(deps: TaModuleDepGraph, importerFileId: int32, importedFileId: int32): void {
	if (edgeExists(deps, importerFileId, importedFileId)) return;
	const edge: TaDepEdge = { importerFileId, importedFileId };
	deps.edges.push(edge);
	// Maintain reverse adjacency index
	while (deps.reverseAdj.length <= importedFileId) {
		const empty: int32[] = [];
		deps.reverseAdj.push(empty);
	}
	deps.reverseAdj[importedFileId].push(importerFileId);
}

export function clearImportsFor(deps: TaModuleDepGraph, fileId: int32): void {
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

export function getDirectImporters(deps: TaModuleDepGraph, fileId: int32): int32[] {
	if (fileId < 0 || fileId >= deps.reverseAdj.length) return [];
	const rev = deps.reverseAdj[fileId];
	const result: int32[] = [];
	for (let i = 0; i < rev.length; i = i + 1) {
		result.push(rev[i]);
	}
	return result;
}

// BFS: returns all files that transitively depend on the given file
export function getTransitiveDependents(deps: TaModuleDepGraph, fileId: int32): int32[] {
	const result: int32[] = [];
	const queue: int32[] = [];
	const visited: HashSet<int32> = new HashSet<int32>();
	visited.add(fileId);  // don't include seed in results
	queue.push(fileId);

	while (queue.length > 0) {
		const current = queue.shift();
		const importers = getDirectImporters(deps, current);
		for (const imp of importers) {
			if (!visited.has(imp)) {
				visited.add(imp);
				result.push(imp);
				queue.push(imp);
			}
		}
	}
	return result;
}

// ===== Forward Edge Queries =====

// Get all fileIds that `fileId` imports (forward edges)
export function getDirectImports(deps: TaModuleDepGraph, fileId: int32): int32[] {
	const result: int32[] = [];
	for (const edge of deps.edges) {
		if (edge.importerFileId === fileId) {
			result.push(edge.importedFileId);
		}
	}
	return result;
}

// Detect if importing `targetId` from `sourceId` creates a cycle.
// DFS from targetId following forward edges. Returns cycle path if reaches sourceId, [] otherwise.
export function detectCycle(deps: TaModuleDepGraph, sourceId: int32, targetId: int32): int32[] {
	if (sourceId === targetId) return [sourceId];
	const visited: int32[] = [];
	const stack: int32[] = [];
	const parent: int32[] = [];
	stack.push(targetId);
	parent.push(-1);

	while (stack.length > 0) {
		const current = stack.pop();
		const _parent = parent.pop();
		if (int32ListContains(visited, current)) continue;
		visited.push(current);

		if (current === sourceId) {
			// Found cycle — reconstruct path
			const path: int32[] = [sourceId, targetId];
			return path;
		}

		const imports = getDirectImports(deps, current);
		for (let i = 0; i < imports.length; i = i + 1) {
			if (!int32ListContains(visited, imports[i])) {
				stack.push(imports[i]);
				parent.push(current);
			}
		}
	}
	return [];
}

// ===== Helpers =====

function int32ListContains(list: int32[], val: int32): boolean {
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
	assert int32ListContains(result, 0);
	assert int32ListContains(result, 1);
}

test "diamond: A->B, A->C, B->D, C->D" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);  // A imports B
	recordModuleImport(deps, 0, 2);  // A imports C
	recordModuleImport(deps, 1, 3);  // B imports D
	recordModuleImport(deps, 2, 3);  // C imports D
	const result = getTransitiveDependents(deps, 3);
	assert result.length === 3;
	assert int32ListContains(result, 0);
	assert int32ListContains(result, 1);
	assert int32ListContains(result, 2);
}

test "cycle: A->B->A does not infinite loop" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);  // A imports B
	recordModuleImport(deps, 1, 0);  // B imports A
	const result = getTransitiveDependents(deps, 0);
	assert result.length === 1;
	assert int32ListContains(result, 1);
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
