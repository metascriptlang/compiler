// Ordered: `-lm` must follow the objects that reference math functions.

let _linkFlags: Set<string> | null = null;
let _linkObjects: Set<string> | null = null;

export function linkFlags(): Set<string> {
	if (_linkFlags == null) _linkFlags = new Set<string>();
	return _linkFlags;
}

export function linkObjects(): Set<string> {
	if (_linkObjects == null) _linkObjects = new Set<string>();
	return _linkObjects;
}

export function resetLinkState(): void {
	_linkFlags = new Set<string>();
	_linkObjects = new Set<string>();
}
