import { Box } from "./box";

export function peek(b: Box<float64>): string {
	return b.v.toString();
}
