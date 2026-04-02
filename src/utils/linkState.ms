// Global link state — one linker invocation, one state.
// Both checker (@passL/@link) and compile (link step) access this.
// Lazy init: C codegen can't emit module-level Set construction.

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
