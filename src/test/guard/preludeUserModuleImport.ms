// guard: build.ms globalImports may name USER modules — the prelude loader
// must resolve them by their own path, not remap them into the std tree.
//
// INVARIANT: loadPreludeOne (checker/checkPass.ms) rewrites a specifier into
//   stdPath ONLY for `std/`-prefixed specifiers. Any other specifier (absolute
//   project path injected via build.ms globalImports) is read as-is. The
//   specifier is extension-less; the loader probes backendExt then .ms.
//
// RED MEANS: the loader mangled the non-std specifier (historically an
//   unconditional `specifier.slice(4)` glued onto stdPath), the readFile
//   probes all missed, the module was SILENTLY skipped, and the exported
//   symbol never reached the prelude scope.

import { cwd } from "std/process";
import { join } from "std/fs/path";
import { setExtraGlobalImports } from "../../checker/prelude";
import { buildPreludeContext, injectPrelude, getSharedIdentCache } from "../../checker/checkPass";
import { createContextWithCache } from "../../checker/context";
import { resolveRuntimeDir } from "../../utils/path";

test "a user module listed in extra globalImports lands in the prelude scope" {
	const specifier = cwd() + "/src/test/guard/fixtures/preludeUserModule";
	setExtraGlobalImports([specifier]);
	const stdPath = join(resolveRuntimeDir(), "std");
	const ctx = buildPreludeContext(stdPath, ".cms");
	setExtraGlobalImports([]);

	let found = false;
	for (const sym of ctx.table.current.symbols.values()) {
		if (sym.name === "neonGuardPreludeProbe") found = true;
	}
	assert found, "user module in globalImports was not loaded into the prelude scope";
}

// A converter exported by a globalImports module must reach each MODULE context:
// tryConverterAtBoundary reads ctx.converterTargets + ctx.macroBodyRegistry, both
// per-module — so injectPrelude has to carry the pair table AND the macro-engine
// registries across, the same way the import branch (collectPass) does for
// explicit imports. Tier: prelude inject = origin 2, shadowed by both local
// decls (0) and explicit imports (1).
test "prelude converter pair and macro body survive injectPrelude" {
	const specifier = cwd() + "/src/test/guard/fixtures/preludeConverter";
	setExtraGlobalImports([specifier]);
	const stdPath = join(resolveRuntimeDir(), "std");
	const preludeCtx = buildPreludeContext(stdPath, ".cms");
	setExtraGlobalImports([]);
	assert preludeCtx.converterTargets.has("VNodeFix"), "converter pair not collected in prelude ctx";

	const modCtx = createContextWithCache(getSharedIdentCache(preludeCtx));
	injectPrelude(modCtx, preludeCtx);
	assert modCtx.converterTargets.has("VNodeFix"), "converter pair not injected into module ctx";
	const convName = modCtx.converterTargets.get("VNodeFix");
	assert convName !== null, "converter name missing from injected pair table";
	if (convName !== null) {
		assert modCtx.macroBodyRegistry.has(convName), "converter macro body not injected into module ctx";
	}
}
