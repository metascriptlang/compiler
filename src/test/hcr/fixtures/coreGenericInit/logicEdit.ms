import { Box, Tagged } from "../lib/lib";
export function appBox(): Box<int32> {
	return new Box<int32>(350);
}
export function appText(): Box<string> {
	return new Box<string>("app");
}
export function appTagged(): Tagged<int32> {
	return new Tagged<int32>(4, "app");
}
