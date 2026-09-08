import { bug137Iface } from "./bug137helper";

bug137Iface(0);

test "bug137: an empty interfaceExtends crosses the macro wire without a Nil walk" {
	const s: Bug137Shape = { a: 5 };
	assert s.a === 5;
}
