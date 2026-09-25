import { logTwice } from "./tpl";

export async function fa(n: int32): Promise<int32> {
	logTwice(n);
	logTwice(n + 1);
	return n + 1;
}
