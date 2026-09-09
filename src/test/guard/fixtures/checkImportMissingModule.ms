import { anything } from "./noSuchModule";

export function checkImportMissingModuleUse(): int32 {
	return anything;
}
