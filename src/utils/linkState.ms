// Global link state — one linker invocation, one state.
// Both checker (@passL/@link) and compile (link step) access this.
// Ordered Set<string>: iteration order matters for linker symbol resolution
// (e.g. `-lm` must follow objects that reference math functions).
// Lazy init accommodates compiler-hosted code where module-level constructors
// run before globals referenced by their constructors (e.g. INITIAL_CAPACITY
// from std/core/struct) are initialized; preludes-first ordering in
// compile.ms:loadAndCheckGraph fixes this, but keeping lazy init for safety.

let _linkFlags: Set<string> = null as unknown as Set<string>;
let _linkObjects: Set<string> = null as unknown as Set<string>;

export function linkFlags(): Set<string> {
	if (_linkFlags === null) _linkFlags = new Set<string>();
	return _linkFlags;
}

export function linkObjects(): Set<string> {
	if (_linkObjects === null) _linkObjects = new Set<string>();
	return _linkObjects;
}

export function resetLinkState(): void {
	_linkFlags = new Set<string>();
	_linkObjects = new Set<string>();
}
