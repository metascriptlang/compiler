import { Node } from "std/meta";

export struct QueryLocal { size: int32; }

export macro refuseTypeArg(value: Node): Node {
	const shape = getTypeArg();
	error("refuseTypeArg: the type argument is refused here", shape);
	return value;
}

export macro refuseNamedImpl(value: Node): Node {
	const shape = getTypeImpl(QueryLocal);
	error("refuseNamedImpl: the named type is refused here", shape);
	return value;
}

export macro refuseBound(value: Node): Node {
	const bound = bindSym("QueryLocal");
	error("refuseBound: the bound symbol is refused here", bound);
	return value;
}
