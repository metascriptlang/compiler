import * as state from "./state";

export function report(): string {
	const last = state.names[state.names.length - 1];
	return `${state.count} ${state.names.length} ${last}`;
}
