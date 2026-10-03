// bug643 — same-named nominal elements retain their array layout
// Symptom: clang reports a missing field on the other module's element type.
// Root cause: array type names discarded the element Symbol's module identity.
// Fix: derive nominal array names with the existing nominal C-name resolver.

import { forwardLayout } from "../corpus/programs/675-nominalArrayIdentity/forward";
import { reverseLayout } from "../corpus/programs/675-nominalArrayIdentity/reverse";

test "bug643: different nominal array layouts coexist" {
	assert forwardLayout() == "5 2";
}

test "bug643: reversed nominal array layouts coexist" {
	assert reverseLayout() == "2 5";
}
