export interface Event { type: string; stopped: boolean; }

export function stopPropagation(this e: Event): void {
	e.stopped = true;
}
