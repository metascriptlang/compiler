import { reload, lastReload, reloadKindName, HcrReloadKind } from "std/hcr";

for (let i = 0; i < 3; i += 1) {
	const kind = reload();
	if (kind != HcrReloadKind.NoChange) console.log(`unexpected ${reloadKindName(kind)} ${lastReload().reason}`);
}
console.log(`reload without --hcr: ${reloadKindName(reload())}`);
