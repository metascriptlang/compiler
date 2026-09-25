import { midValue } from "./mid";

export function viewValue(): int32 {
	const v = midValue();
	return (v + 1) as int32;
}
