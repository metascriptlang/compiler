// GUARD-CHECK-FAIL Macro 'refuse': the explicit type argument is refused
// GUARD-CHECK-FAIL macroTypeArgumentCoordinates.ms:11:

import { refuse } from "./fixtures/macroTypeArgumentReject";

struct Thing {
	size: int32;
}

const thing: Thing = { size: 3 };
refuse<Thing>(thing);
