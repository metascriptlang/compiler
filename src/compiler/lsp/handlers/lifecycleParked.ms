import { TransAmDb, createTransAmDb, dbSetFileText } from "../../transam/index";
import { parseJson } from "std/serialize/json/parser";
import { JsonKind, JsonValue } from "std/serialize/json/types";
import { getDynamicField, asString, asInt32 } from "std/serialize/json/accessors";
import { lspJsonString, lspUriToPath } from "../protocol";
import { handleDefinition } from "./definition";
import { handleReferences, handleRename } from "./queries";

function testDb(uri: string, source: string): TransAmDb {
	const db = createTransAmDb(100);
	dbSetFileText(db, lspUriToPath(uri), source);
	return db;
}

function testQueryResult(json: string, id: int32): JsonValue {
	const parsed = parseJson(json);
	if (!parsed.ok) throw new Error(parsed.error);
	const message = parsed.value;
	if (message.kind != JsonKind.Object || message.keys.indexOf("result") < 0
		|| message.getDynamicField("jsonrpc").asString() != "2.0"
		|| message.getDynamicField("id").asInt32(-1) != id
		|| message.getDynamicField("error").kind != JsonKind.Null) {
		throw new Error("Expected query result: " + json);
	}
	return message.getDynamicField("result");
}

function testRange(range: JsonValue): string {
	const start = range.getDynamicField("start");
	const end = range.getDynamicField("end");
	return `${start.getDynamicField("line").asInt32(-1)}:${start.getDynamicField("character").asInt32(-1)}-${end.getDynamicField("line").asInt32(-1)}:${end.getDynamicField("character").asInt32(-1)}`;
}

test "definition returns the declaration name range" {
	const db = testDb("file:///test.ms", "const myVar = 42;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6}}";
	const result = testQueryResult(handleDefinition("7", params, db), 7);
	assert result.getDynamicField("uri").asString() == "file:///test.ms";
	assert testRange(result.getDynamicField("range")) == "0:6-0:11";
}

test "definition for an unknown document returns null" {
	const db = createTransAmDb(100);
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"position\":{\"line\":0,\"character\":0}}";
	assert testQueryResult(handleDefinition("8", params, db), 8).kind == JsonKind.Null;
}

test "definition for an unknown position returns null" {
	const db = testDb("file:///test.ms", "const x = 1;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":99,\"character\":0}}";
	assert testQueryResult(handleDefinition("9", params, db), 9).kind == JsonKind.Null;
}

test "references from declaration and use exclude a shadowed parameter" {
	const uri = "file:///lsp-references.ms";
	const source = "const abc = 1;\nfunction read(abc: int32): int32 { return abc; }\nconst def = abc + 2;";
	const db = testDb(uri, source);
	const positions = ["{\"line\":0,\"character\":6}", "{\"line\":2,\"character\":12}"];
	for (const position of positions) {
		const params = `{"textDocument":{"uri":${lspJsonString(uri)}},"position":${position},"context":{"includeDeclaration":true}}`;
		const result = testQueryResult(handleReferences("50", params, db), 50);
		assert result.kind == JsonKind.Array;
		if (result.kind == JsonKind.Array) {
			assert result.items.length == 2;
			const ranges = new HashSet<string>();
			for (const item of result.items) {
				assert item.getDynamicField("uri").asString() == uri;
				ranges.add(testRange(item.getDynamicField("range")));
			}
			assert ranges.has("0:6-0:9");
			assert ranges.has("2:12-2:15");
		}
	}
}

test "references for an unknown document return an empty array" {
	const db = createTransAmDb(100);
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"position\":{\"line\":0,\"character\":0}}";
	const result = testQueryResult(handleReferences("51", params, db), 51);
	assert result.kind == JsonKind.Array;
	if (result.kind == JsonKind.Array) assert result.items.length == 0;
}

test "rename from declaration and use edits only the selected symbol" {
	const uri = "file:///lsp-rename.ms";
	const source = "const abc = 1;\nfunction read(abc: int32): int32 { return abc; }\nconst def = abc + 2;";
	const db = testDb(uri, source);
	const positions = ["{\"line\":0,\"character\":6}", "{\"line\":2,\"character\":12}"];
	for (const position of positions) {
		const params = `{"textDocument":{"uri":${lspJsonString(uri)}},"position":${position},"newName":"xyz"}`;
		const changes = testQueryResult(handleRename("60", params, db), 60).getDynamicField("changes");
		assert changes.kind == JsonKind.Object;
		if (changes.kind == JsonKind.Object) assert changes.keys.length == 1;
		const edits = changes.getDynamicField(uri);
		assert edits.kind == JsonKind.Array;
		if (edits.kind == JsonKind.Array) {
			assert edits.items.length == 2;
			const ranges = new HashSet<string>();
			for (const item of edits.items) {
				assert item.getDynamicField("newText").asString() == "xyz";
				ranges.add(testRange(item.getDynamicField("range")));
			}
			assert ranges.has("0:6-0:9");
			assert ranges.has("2:12-2:15");
		}
	}
}

test "rename for an unknown document returns null" {
	const db = createTransAmDb(100);
	const params = "{\"textDocument\":{\"uri\":\"file:///nope.ms\"},\"position\":{\"line\":0,\"character\":0},\"newName\":\"xyz\"}";
	assert testQueryResult(handleRename("61", params, db), 61).kind == JsonKind.Null;
}

test "rename with an empty new name returns null" {
	const db = testDb("file:///test.ms", "const x = 1;");
	const params = "{\"textDocument\":{\"uri\":\"file:///test.ms\"},\"position\":{\"line\":0,\"character\":6}}";
	assert testQueryResult(handleRename("62", params, db), 62).kind == JsonKind.Null;
}
