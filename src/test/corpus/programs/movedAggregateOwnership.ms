// @skip-js: lifecycle hooks run only on the native ownership backend
// @skip-raiser: lifecycle hooks run only on the native ownership backend
// @stdout: GUARD-OK

import "../../guard/freshAggregateResultTransferredOnce";
import "../../guard/movedValueClearsPlainFields";
import "../../guard/movedScalarDistinctIsDestroyedZeroed";
import "../../guard/aggregateConstructionFailureReleasesFields";
