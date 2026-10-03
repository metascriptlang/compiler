import { forwardLayout } from "../corpus/programs/675-nominalArrayIdentity/forward";
import { reverseLayout } from "../corpus/programs/675-nominalArrayIdentity/reverse";

test "nominalArrayLayout: different nominal array layouts coexist" {
	assert forwardLayout() == "5 2";
}

test "nominalArrayLayout: reversed nominal array layouts coexist" {
	assert reverseLayout() == "2 5";
}
