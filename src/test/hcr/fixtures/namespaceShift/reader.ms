import * as state from "./state";

export function report(): string {
	return `${state.count} ${state.names.length}`;
}
