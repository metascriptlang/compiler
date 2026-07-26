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
import "./typeCoercion";
import "./arrayElementRepr";
import "./unionNarrowing";
import "./unionNarrow";
import "./toStringResolve";
import "./bitwiseCheck";
import "./typeAliasStruct";
import "./literalCoercion";
import "./discriminatedUnion";
import "./classGeneric";
import "./macroNodeFieldTyped";
import "./explicitTargGenericBody";
import "./anonOptionalField";
import "./refTruthiness";
import "./genericArraySlice";
import "./crossModuleGenericCtor";
import "./tryResultPropagation";
import "./nullCheckValueType";
import "./nullValueType";
import "./enumValues";
import "./matchValueType";
import "./defaultArgs";
import "./anonStructResolve";
import "./tryResultArray";
import "./classMemberElseIf";
import "./crossModuleGlobal";
import "./closureCall";
import "./nrvoReassign";
import "./closureEnvArrayType";
import "./toStringUnified";
import "./incompleteStruct";
import "./anonStructCast";
import "./nullVarType";
import "./matchResultDrc";
import "./outParamName";
import "./userDestructor";
