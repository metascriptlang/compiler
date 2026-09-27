import { Node, bindSym } from "std/meta";
import { HcrReloadKind, HcrReloadResult } from "./types";

export { HcrReloadKind, HcrReloadResult, reloadKindName } from "./types";

when (hcr) {
	import { engineReload, engineLastReload } from "./engine";

	export macro reload(): Node {
		return quote { ${bindSym("engineReload")}() };
	}

	export function lastReload(): HcrReloadResult {
		return engineLastReload();
	}
} else {
	export macro reload(): Node {
		return quote { ${bindSym("HcrReloadKind")}.NoChange };
	}

	export function lastReload(): HcrReloadResult {
		return { kind: HcrReloadKind.NoChange, modules: [], reason: "" };
	}
}
