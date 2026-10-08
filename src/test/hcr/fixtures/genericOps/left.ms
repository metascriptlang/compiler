import { capture } from "./cell";

const pair = capture<int32>(7);
export function left(): int32 {
	pair[1](9);
	return pair[0]();
}
