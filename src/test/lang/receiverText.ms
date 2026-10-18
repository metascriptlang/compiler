import { makeCellA } from "./fixtures/receiverTextA";
import { makeCellB } from "./fixtures/receiverTextB";

test "a toString extension binds only its own declaration's type" {
	assert String(makeCellA()) == "A(left)";
	assert "" + makeCellA() == "A(left)";
	assert `${makeCellA()}` == "A(left)";
}

test "a same-named type without toString keeps the default text" {
	const text = String(makeCellB());
	assert text.indexOf("count") >= 0;
	assert text.indexOf("A(") < 0;
}
