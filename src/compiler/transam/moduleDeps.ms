// Trans-Am Module Dependencies — tracks import graph, BFS invalidation
//
// When file A imports file B, we record the edge. When B changes,
// getTransitiveDependents(B) returns all files transitively importing B
// so they can be marked RED.
//
// Arrays passed by pointer — bare T[] types.



// ===== Module Dependency Graph =====

export class TaModuleDepGraph {
	forwardAdj: int32[][];  // importerFileId → [importedFileId, ...] in import order
	reverseAdj: int32[][];  // importedFileId → [importerFileId, ...] for O(1) reverse lookup
	registeredAt: int32[];  // fileId → revision when exports registered (-1 = never)
}

export function createModuleDepGraph(): TaModuleDepGraph {
	return { forwardAdj: [], reverseAdj: [], registeredAt: [] };
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
	if (imported >= deps.reverseAdj.length) return false;
	for (const existing of deps.reverseAdj[imported]) {
		if (existing == importer) return true;
	}
	return false;
}

function ensureAdjacency(adj: int32[][], fileId: int32): void {
	while (adj.length <= fileId) {
		const empty: int32[] = [];
		adj.push(empty);
	}
}

export function recordModuleImport(
	deps: TaModuleDepGraph,
	importerFileId: int32,
	importedFileId: int32,
): void {
	if (edgeExists(deps, importerFileId, importedFileId)) return;
	ensureAdjacency(deps.forwardAdj, importerFileId);
	ensureAdjacency(deps.reverseAdj, importedFileId);
	deps.forwardAdj[importerFileId].push(importedFileId);
	deps.reverseAdj[importedFileId].push(importerFileId);
}

export function clearImportsFor(deps: TaModuleDepGraph, fileId: int32): void {
	if (fileId < 0 || fileId >= deps.forwardAdj.length) return;
	const imports = deps.forwardAdj[fileId];
	for (const imported of imports) {
		const rev = deps.reverseAdj[imported];
		const at = rev.indexOf(fileId);
		for (let j = at; j < rev.length - 1; j++) {
			rev[j] = rev[j + 1];
		}
		rev.pop();
	}
	imports.length = 0;
}

// ===== Queries =====

export function getDirectImporters(deps: TaModuleDepGraph, fileId: int32): int32[] {
	if (fileId < 0 || fileId >= deps.reverseAdj.length) return [];
	const rev = deps.reverseAdj[fileId];
	const result: int32[] = [];
	for (const importer of rev) {
		result.push(importer);
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

// Get all fileIds that `fileId` imports (forward edges), in import order
export function getDirectImports(deps: TaModuleDepGraph, fileId: int32): int32[] {
	const result: int32[] = [];
	if (fileId < 0 || fileId >= deps.forwardAdj.length) return result;
	for (const imported of deps.forwardAdj[fileId]) {
		result.push(imported);
	}
	return result;
}

// Detect if importing `targetId` from `sourceId` creates a cycle.
// DFS from targetId following forward edges. Returns cycle path if reaches sourceId, [] otherwise.
export function detectCycle(deps: TaModuleDepGraph, sourceId: int32, targetId: int32): int32[] {
	if (sourceId == targetId) return [sourceId];
	const visited: int32[] = [];
	const stack: int32[] = [targetId];

	while (stack.length > 0) {
		const current = stack.pop();
		if (int32ListContains(visited, current)) continue;
		visited.push(current);

		if (current == sourceId) return [sourceId, targetId];

		for (const imported of getDirectImports(deps, current)) {
			if (!int32ListContains(visited, imported)) stack.push(imported);
		}
	}
	return [];
}

// ===== Helpers =====

function int32ListContains(list: int32[], val: int32): boolean {
	for (const item of list) {
		if (item == val) return true;
	}
	return false;
}

// ===== Tests =====
test "empty graph has no imports or importers" {
	const deps = createModuleDepGraph();
	assert getDirectImports(deps, 0).length == 0;
	assert getDirectImporters(deps, 0).length == 0;
}

test "record import is visible both ways" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);
	assert getDirectImports(deps, 0).length == 1;
	assert getDirectImports(deps, 0)[0] == 1;
	assert getDirectImporters(deps, 1)[0] == 0;
}

test "no duplicate edges" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);
	recordModuleImport(deps, 0, 1);
	assert getDirectImports(deps, 0).length == 1;
	assert getDirectImporters(deps, 1).length == 1;
}

test "direct importers" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);  // 0 imports 1
	recordModuleImport(deps, 2, 1);  // 2 imports 1
	const imps = getDirectImporters(deps, 1);
	assert imps.length == 2;
}

test "transitive: A->B->C" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);  // 0 imports 1
	recordModuleImport(deps, 1, 2);  // 1 imports 2
	const result = getTransitiveDependents(deps, 2);
	assert result.length == 2;
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
	assert result.length == 3;
	assert int32ListContains(result, 0);
	assert int32ListContains(result, 1);
	assert int32ListContains(result, 2);
}

test "cycle: A->B->A does not infinite loop" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);  // A imports B
	recordModuleImport(deps, 1, 0);  // B imports A
	const result = getTransitiveDependents(deps, 0);
	assert result.length == 1;
	assert int32ListContains(result, 1);
}

test "no dependents" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);
	const result = getTransitiveDependents(deps, 0);
	assert result.length == 0;
}

test "clear removes edges for file" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);
	recordModuleImport(deps, 0, 2);
	recordModuleImport(deps, 1, 2);
	clearImportsFor(deps, 0);
	assert getDirectImports(deps, 0).length == 0;
	assert getDirectImports(deps, 1).length == 1;
	assert getDirectImports(deps, 1)[0] == 2;
	assert getDirectImporters(deps, 2).length == 1;
}

test "direct imports keep import order on a diamond across record and clear" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 2);
	recordModuleImport(deps, 0, 1);
	recordModuleImport(deps, 1, 3);
	recordModuleImport(deps, 2, 3);
	let imports = getDirectImports(deps, 0);
	assert imports.length == 2 && imports[0] == 2 && imports[1] == 1;
	assert getDirectImporters(deps, 3).length == 2;
	clearImportsFor(deps, 0);
	assert getDirectImports(deps, 0).length == 0;
	recordModuleImport(deps, 0, 3);
	recordModuleImport(deps, 0, 1);
	imports = getDirectImports(deps, 0);
	assert imports.length == 2 && imports[0] == 3 && imports[1] == 1;
	clearImportsFor(deps, 1);
	assert getDirectImporters(deps, 3).length == 2;
	assert getDirectImporters(deps, 3)[0] == 2 && getDirectImporters(deps, 3)[1] == 0;
}

test "direct imports of an unknown file are empty" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);
	assert getDirectImports(deps, 7).length == 0;
	assert getDirectImports(deps, -1).length == 0;
	clearImportsFor(deps, 7);
	assert getDirectImports(deps, 0).length == 1;
}

test "reverse index after clear" {
	const deps = createModuleDepGraph();
	recordModuleImport(deps, 0, 1);
	recordModuleImport(deps, 2, 1);
	recordModuleImport(deps, 0, 3);
	// reverseAdj[1] should have [0, 2]
	let imps = getDirectImporters(deps, 1);
	assert imps.length == 2;
	// Clear file 0's imports
	clearImportsFor(deps, 0);
	// reverseAdj[1] should now only have [2]
	imps = getDirectImporters(deps, 1);
	assert imps.length == 1;
	assert imps[0] == 2;
	// reverseAdj[3] should be empty (0 was the only importer)
	imps = getDirectImporters(deps, 3);
	assert imps.length == 0;
}

test "registeredAt tracking" {
	const deps = createModuleDepGraph();
	assert getRegisteredAt(deps, 0) == -1;
	setRegisteredAt(deps, 0, 5);
	assert getRegisteredAt(deps, 0) == 5;
	resetRegisteredAt(deps, 0);
	assert getRegisteredAt(deps, 0) == -1;
}
