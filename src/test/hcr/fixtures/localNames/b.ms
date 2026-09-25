import { logTwice } from "./tpl";

export async function fb(n: int32): Promise<int32> {
	logTwice(n * 2);
	return n * 2;
}
