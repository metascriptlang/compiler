import { LIMIT, bump, counter } from "./logic";

@exportName("probe")
export function probe(): int32 {
	return LIMIT + bump() + counter;
}
