import { twice } from "./lib";
export function unusedPair(): int32 {
	return twice<int32>(7).length as int32;
}
export function label(): string {
	return "a";
}
