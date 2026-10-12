@compile("./first.c");
@compile("./second.c");

import { hcrNativeFirst, hcrNativeSecond } from "./native.h";

export function nativeSum(): int32 {
	return hcrNativeFirst() + hcrNativeSecond();
}
