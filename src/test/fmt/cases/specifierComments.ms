import { assertFmtLossless, assertFmtIdempotent } from "../roundtrip";

const imports = "import {\n\tNode, NodeKind,\n\t// NodeData variants\n\tProgramData, BlockStmtData,\n\tIfStmtData, // branches\n\t// end\n} from \"../ast/node\";\n";

test "fmt: comments inside an import list stay in place" {
	assert assertFmtLossless(imports);
}

test "fmt: comments inside an import list are stable" {
	assert assertFmtIdempotent(imports);
}

test "fmt: comments inside a re-export list stay in place" {
	assert assertFmtLossless("export {\n\tsendText, sendJson,\n\t// Phase 4\n\tsetHeader, end,\n} from \"./server\";\n");
}

test "fmt: a comment before the only re-exported name stays inside the list" {
	assert assertFmtLossless("export {\n\t// Typed CRUD via the class\n\tSurreal,\n} from \"./typed\";\n");
}
