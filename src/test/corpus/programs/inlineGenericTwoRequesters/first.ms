import { forward } from "./helper";

export function first(): Result<int32, string> {
	return forward<int32>(7);
}
