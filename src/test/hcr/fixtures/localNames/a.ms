import { logTwice } from "./tpl";

export async function fa(n: int32): Promise<int32> {
	logTwice(n);
	return n + 1;
}
