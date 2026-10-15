import { pick } from "./first";
export { pick } from "./second";
export { pick as firstPick } from "./first";

export function local(): int32 {
	return pick();
}
