import { Pair } from "./pair";
export interface Holder { pair: Pair<string, int32>; }

export function makeHolder(): Holder {
	return { pair: new Pair<string, int32>("a", 3) };
}
