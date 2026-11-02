import { readIt, tagged, Box, Need } from "./fit";

export function helper(n: int32): string { return `h${n}`; }

export function use(n: int32): string {
	const box = new Box();
	return `${readIt(n)} ${tagged(n)} ${box.need == Need.Items ? "items" : "value"}`;
}
