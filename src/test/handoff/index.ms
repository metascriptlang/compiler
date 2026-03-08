// Phase Handoff Tests
//
// Verify type flow across phase boundaries (checker→transform→codegen).
// Each file isolates a specific handoff route.

import "./helpers";
import "./checkerTypes";
import "./ccgIntroducedPtr";
import "./getTypeSize";
import "./classCodegen";
import "./interfaceLifecycle";
import "./classLifecycle";
import "./postTransform";
import "./drcInject";
import "./maybeCollapse";
