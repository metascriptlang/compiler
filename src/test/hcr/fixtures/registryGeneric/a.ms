import { echo } from "./cell";

export function runA(): string {
	return echo<int32>(5).toString();
}
