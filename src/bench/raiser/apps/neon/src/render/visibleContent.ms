export interface VisibleContentPosition {
	minIndexForVisible: int32;
	autoscrollToTopThreshold: number | null;
}

export function visibleContentAttr(minIndexForVisible: number, autoscrollToTopThreshold: number | null): string {
	if (minIndexForVisible < 0 || Math.floor(minIndexForVisible) !== minIndexForVisible) {
		throw `maintainVisibleContentPosition: minIndexForVisible must be a non-negative integer, got ${minIndexForVisible}`;
	}
	if (autoscrollToTopThreshold === null) { return `${minIndexForVisible}`; }
	return `${minIndexForVisible},${autoscrollToTopThreshold as number}`;
}

export function parseVisibleContent(value: string): VisibleContentPosition | null {
	if (value === "") { return null; }
	const comma = value.indexOf(",");
	const index = comma < 0 ? value : value.substring(0, comma);
	const position: VisibleContentPosition = {
		minIndexForVisible: parseInt(index) as int32,
		autoscrollToTopThreshold: comma < 0 ? null : parseFloat(value.substring(comma + 1, value.length)) as number,
	};
	return position;
}
