import { put } from "./shapes";
import * as shapes from "./shapes";
export function go(): string {
	return `${put("x")} ${put(2)} ${put([1, 2])} ${shapes.put(3)}`;
}
