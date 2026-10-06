// GUARD-CHECK-FAIL Macro 'refuseField': the explicit type field is refused
// GUARD-CHECK-FAIL macroTypeArgumentFieldCoordinates.ms:12:

import { refuseField } from "./fixtures/macroTypeArgumentReject";

struct Thing {
	size: int32;
}

const thing: Thing = { size: 3 };

refuseField<Thing>(thing);
