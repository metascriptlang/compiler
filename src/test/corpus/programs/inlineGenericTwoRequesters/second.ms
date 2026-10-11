import { forward } from "./helper";

export function second(): Result<int32, string> {
	return forward<int32>(9);
}
