import { execFileSync } from "node:child_process";
import { existsSync, realpathSync, readFileSync, mkdirSync } from "node:fs";
import { join, resolve, dirname, sep } from "node:path";

const MS_RE = /\.ms(\?.*)?$/;

// Vite hands ids through the platform's real path (/tmp is a symlink to
// /private/tmp on macOS) while plugin options and the manifest keep the
// spelling each side was given, so both have to go through realpath before
// they can be compared.
function canon(p) {
	try { return realpathSync(p); } catch { return p; }
}

function stripQuery(id) {
	const q = id.indexOf("?");
	return q === -1 ? id : id.slice(0, q);
}

export default function metascript(options = {}) {
	const msc = options.msc ?? "msc";
	let root = process.cwd();
	// Default inside the project: Vite serves files under root directly, while
	// a tmpdir has to go through /@fs and dies under a stricter server.fs.allow.
	let outDir = options.outDir ? resolve(options.outDir) : join(root, "node_modules/.metascript");
	let entry = options.entry ? canon(resolve(options.entry)) : null;
	let emitted = null;

	// One emit covers the whole graph, so the first .ms resolve pays for all of
	// them; later resolves reuse the tree until a source file changes. The
	// source→output mapping comes from the compiler's manifest — re-deriving it
	// here means replicating project-root discovery, which silently resolves
	// nothing whenever the two disagree.
	function emit() {
		mkdirSync(outDir, { recursive: true });
		// Vite reads the sourceMappingURL comment off the file it loads, so the
		// map only has to exist beside the emitted module.
		const args = ["build", entry, "--target=js", "--split", `--output=${outDir}`];
		if (options.sourcemap !== false) args.push("--sourcemap");
		execFileSync(msc, args, {
			stdio: options.quiet === false ? "inherit" : "pipe",
		});
		const manifest = JSON.parse(readFileSync(join(outDir, "_manifest.json"), "utf8"));
		const bySource = new Map();
		for (const m of manifest.modules) bySource.set(canon(m.source), join(outDir, m.out));
		emitted = { bySource };
	}

	return {
		name: "vite-plugin-metascript",
		enforce: "pre",

		configResolved(config) {
			root = config.root;
			if (!options.outDir) outDir = join(root, "node_modules/.metascript");
			if (entry === null && options.entry) entry = canon(resolve(root, options.entry));
		},

		configureServer(s) {
			// A .ms edit invalidates the whole emitted tree: cross-module type
			// information means one edit can change another module's output.
			s.watcher.on("change", (file) => {
				if (!MS_RE.test(file)) return;
				emitted = null;
				for (const mod of s.moduleGraph.idToModuleMap.values()) {
					if (mod.id && mod.id.startsWith(outDir + sep)) s.moduleGraph.invalidateModule(mod);
				}
				s.ws.send({ type: "full-reload" });
			});
		},

		// Rollup loads the emitted file through its own fs and does not follow
		// the sourceMappingURL comment, so a production bundle maps back to the
		// generated .js unless the map is handed over here. Dev goes through the
		// same hook, which also spares the browser a second request for it.
		load(id) {
			const file = stripQuery(id);
			if (!file.startsWith(outDir + sep) || !file.endsWith(".js")) return null;
			const mapFile = `${file}.map`;
			if (!existsSync(file) || !existsSync(mapFile)) return null;
			const code = readFileSync(file, "utf8");
			return {
				code: code.replace(/\n*\/\/# sourceMappingURL=[^\n]*\n?/, "\n"),
				map: JSON.parse(readFileSync(mapFile, "utf8")),
			};
		},

		resolveId(source, importer) {
			if (!MS_RE.test(source)) return null;
			const base = importer ? dirname(stripQuery(importer)) : root;
			const file = canon(resolve(base, stripQuery(source)));
			if (!existsSync(file)) return null;
			if (entry === null) entry = file;
			if (emitted === null) emit();
			return emitted.bySource.get(file) ?? null;
		},
	};
}
