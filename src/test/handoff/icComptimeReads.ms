import { resetInstantiationState } from "../../checker/instantiate";
import { createTransAmDb, dbSetFileText, dbSetStdPath, dbTypeCheck } from "../../compiler/transam/index";
import { cacheGet } from "../../compiler/transam/cache";
import { getFileId } from "../../compiler/transam/fileInput";
import { TaQueryKind, createQueryKey } from "../../compiler/transam/revision";
import { resolveRuntimeDir } from "../../utils/path";
import { ensureDir } from "../../compiler/io";
import { writeFile } from "std/fs";
import { cwd } from "std/process";

test "a file read by @comptime during a check is a FileText input of that check" {
	resetInstantiationState();
	const dir = `${cwd()}/out/test/icComptimeReads.${performance.now()}`;
	ensureDir(dir);
	const data = `${dir}/data.txt`;
	writeFile(data, "abc\n");
	const main = `${dir}/main.ms`;
	const db = createTransAmDb(100);
	dbSetStdPath(db, resolveRuntimeDir() + "/std");
	dbSetFileText(db, main, `import { readFile } from "std/meta";\nconst n = @comptime { return readFile("${data}").length; };\nconsole.log(\`\${n}\`);\n`);
	const ctx = dbTypeCheck(db, main);
	assert ctx.errors.length == 0, ctx.errors.map((e): string => e.message).join("\n");
	assert db.externalReads.paths.includes(data), `external reads: [${db.externalReads.paths.join(", ")}]`;
	const entry = cacheGet(db.cache, createQueryKey(TaQueryKind.TypeCheck, getFileId(db.fileInput, main)));
	const dataId = getFileId(db.fileInput, data);
	let recorded = false;
	if (entry != null) for (const dep of entry.dependencies) if (dep.queryKind == TaQueryKind.FileText && dep.fileId == dataId) recorded = true;
	assert recorded, `the check of main.ms records no FileText dependency on ${data}`;
}
