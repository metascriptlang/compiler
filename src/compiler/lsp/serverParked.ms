import { ensureDir, realpath, writeFile } from "std/fs";
import { writeStderr } from "std/io";
import { getDynamicField, at, length, asString } from "std/serialize/json/accessors";
import { tmpDir } from "../../utils/path";
import { createMemoryWire, memoryTransport } from "./transport";
import { lspServe } from "./server";
import {
	LspReplay,
	lspTranscript,
	projectUri,
	frames, request, notification, initializeDrain, openParams, changeParams, positionParams,
} from "./replayScenarios";

const SHAPES = "export class Box {\n\tv: int32;\n\tconstructor(v: int32) {\n\t\tthis.v = v;\n\t}\n}\nexport class Holder<T> {\n\titem: T;\n\tconstructor(item: T) {\n\t\tthis.item = item;\n\t}\n}\nexport function takeBox(b: Box): int32 {\n\treturn b.v;\n}\n";
const MAKERS = "import { Box, Holder } from \"./shapes\";\nexport function mkBox(): Box {\n\treturn new Box(4);\n}\nexport function mkHolder(): Holder<Box> {\n\treturn new Holder<Box>(new Box(5));\n}\nexport function readBox(b: Box): int32 {\n\treturn b.v;\n}\n";
const USER = "import { Box, Holder, takeBox } from \"./shapes\";\nconst b: Box = mkBox();\nconst h: Holder<Box> = mkHolder();\nconsole.log(takeBox(b) + readBox(new Box(7)) + h.item.v);\n";

function shapesProject(name: string): string {
	const dir = `${tmpDir()}/mscLspParked/${name}`;
	ensureDir(dir);
	const root = realpath(dir).replaceAll("\\", "/");
	writeFile(`${root}/build.ms`, "const config = { globalImports: [\"./makers\"] };\nexport default config;\n");
	writeFile(`${root}/makers.ms`, MAKERS);
	writeFile(`${root}/shapes.ms`, SHAPES);
	return projectUri(root);
}

function replay(drains: string[][]): LspReplay {
	const chunks: string[] = [];
	for (const drain of drains) chunks.push(drain.join(""));
	const wire = createMemoryWire(chunks);
	const exitCode = lspServe(memoryTransport(wire));
	return lspTranscript(wire.output, exitCode, wire.nextChunk);
}

function publishesOf(r: LspReplay, uri: string): string {
	const publishes: string[] = [];
	for (const m of r.messages) {
		if (m.getDynamicField("method").asString() != "textDocument/publishDiagnostics") continue;
		const params = m.getDynamicField("params");
		if (params.getDynamicField("uri").asString() != uri) continue;
		const diagnostics = params.getDynamicField("diagnostics");
		const items: string[] = [];
		for (let i = 0; i < diagnostics.length(); i++) items.push(diagnostics.at(i).getDynamicField("message").asString());
		publishes.push("[" + items.join("; ") + "]");
	}
	const text = publishes.join("|");
	writeStderr("parked: " + uri + " publishes " + text + "\n");
	return text;
}

function queries(uri: string, methods: string[]): string[] {
	const position = positionParams(uri, 1, 16);
	const bodies: string[] = [];
	let n = 0;
	for (const method of methods) {
		n++;
		const params = method == "rename" ? position.byteSlice(0, position.byteLength - 1) + ",\"newName\":\"renamed\"}" : position;
		bodies.push(request(`"q${n}"`, `textDocument/${method}`, params));
	}
	return frames(bodies);
}

function open(uri: string, text: string): string[] {
	return frames([notification("textDocument/didOpen", openParams(uri, text))]);
}

function edit(uri: string, version: int32, text: string): string[] {
	return frames([notification("textDocument/didChange", changeParams(uri, version, text))]);
}

test "completion then rename leaves the class a build.ms global import returns the class its importer names" {
	const base = shapesProject("completionThenRename");
	const use = base + "use.ms";
	const r = replay([
		initializeDrain(),
		open(use, USER),
		queries(use, ["completion", "rename"]),
		edit(use, 2, USER + "// edited\n"),
	]);
	assert publishesOf(r, use) == "[]|[]";
}

test "opening the module a global import bound but never checked, after an edit, keeps the class its importer names" {
	const base = shapesProject("editThenOpenDependency");
	const use = base + "use.ms";
	const r = replay([
		initializeDrain(),
		open(use, USER),
		edit(use, 2, USER + "// edited\n"),
		open(base + "shapes.ms", SHAPES),
		edit(use, 3, USER + "// edited twice\n"),
	]);
	assert publishesOf(r, use) == "[]|[]|[]";
}
