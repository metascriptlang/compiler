import { readFile } from "std/fs";
import { pcurveBaseTablePath, pcurveBaseTableText } from "../../../tools/crypto/genPcurveTables";

test "the committed p-256 and p-384 base tables are what the generator writes from pcurve" {
	const committed = readFile(pcurveBaseTablePath);
	assert committed.ok;
	assert committed.value == pcurveBaseTableText();
}
