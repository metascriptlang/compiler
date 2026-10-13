import "./macroEmitFirstUse";
import { second } from "./macroEmitSecondUse";

test "a macro that returns an emit directive still expands after a later module expands another macro" {
	assert second == 1;
}
