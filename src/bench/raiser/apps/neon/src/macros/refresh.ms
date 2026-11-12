import {
	Node,
	NodeKind,
	DeclKind,
	define,
	expansionFile,
	childCount,
	childAt,
	stringValue,
	intValue,
	floatValue,
	isFloatLiteral,
} from "std/meta";

function isComponentName(name: string): boolean {
	if (name.length == 0) return false;
	const c = name.charCodeAt(0);
	return c >= 65 && c <= 90;
}

function isPlainParam(name: string): boolean {
	if (name.length == 0) return false;
	for (let i = 0; i < name.length; i += 1) {
		const c = name.charCodeAt(i);
		const letter = (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
		const digit = c >= 48 && c <= 57;
		if (!letter && !digit && c != 95 && c != 36) return false;
	}
	return true;
}

function isStatementWithEffects(kind: NodeKind): boolean {
	return kind == NodeKind.ExprStmt || kind == NodeKind.IfStmt || kind == NodeKind.WhileStmt ||
		kind == NodeKind.ForStmt || kind == NodeKind.ForOfStmt || kind == NodeKind.ForInStmt ||
		kind == NodeKind.BlockStmt || kind == NodeKind.DoWhileStmt || kind == NodeKind.SwitchStmt ||
		kind == NodeKind.MatchStmt || kind == NodeKind.ThrowStmt || kind == NodeKind.TryCatchStmt ||
		kind == NodeKind.ComptimeBlock;
}

function intersects(names: string[], set: string[]): boolean {
	for (const n of names) {
		if (set.indexOf(n) >= 0) return true;
	}
	return false;
}

function moduleKey(path: string): string {
	let p = path.split("\\").join("/");
	for (const ext of [".cms", ".jms", ".ms"]) {
		if (p.endsWith(ext)) {
			p = p.slice(0, p.length - ext.length);
			break;
		}
	}
	if (p.endsWith("/index")) p = p.slice(0, p.length - 6);
	let parts: string[] = [];
	for (const part of p.split("/")) {
		if (part == ".") continue;
		if (part == ".." && parts.length > 0 && parts[parts.length - 1] != "..") {
			parts.pop();
			continue;
		}
		parts.push(part);
	}
	return parts.join("/");
}

function importKey(file: string, source: string): string {
	if (!source.startsWith(".")) return "";
	const path = file.split("\\").join("/");
	return moduleKey(path.slice(0, path.lastIndexOf("/")) + "/" + source);
}

export macro refreshTypeKey(value: Node): Node {
	let key = "";
	const type = value.nodeType;
	if (type !== null) {
		let stack: Node[] = [type as Node];
		while (stack.length > 0) {
			const m = stack.pop() as Node;
			key = key + "|" + m.kind.toString();
			if (m.kind == NodeKind.Identifier) {
				key = key + ":" + m.name;
			} else if (m.kind == NodeKind.TypeObject) {
				key = key + ":" + m.typExprTypeName + ":" + m.typExprFieldNames.join(",");
			} else if (m.kind == NodeKind.TypeArray) {
				key = key + ":" + m.typExprSize.toString();
			}
			const k = childCount(m);
			for (let i = k - 1; i >= 0; i -= 1) stack.push(childAt(m, i));
		}
	}
	return { kind: NodeKind.StringLiteral, line: value.line, column: value.column, value: key };
}

export macro refreshPass(mod: Node): Node {
	if (define("refresh") == "" && define("hcr") == "") return mod;
	const file = expansionFile();
	const ML = mod.line;
	const MC = mod.column;
	const stmts = mod.programStmts;

	let imported: string[] = [];
	let importSources: string[] = [];
	let importNames: string[][] = [];
	let sideEffects = false;
	let jobRoots: Node[][] = [stmts];
	let varJobs: int32[] = [];
	let compAt: int32[] = [];
	let setupJob: int32[] = [];
	let tmplJob: int32[] = [];
	let declared: string[][] = [];
	let mutable: string[][] = [];
	let stateAt: int32[][] = [];
	let stateJob: int32[][] = [];

	for (let i = 0; i < stmts.length; i += 1) {
		const s = stmts[i];
		if (s.kind == NodeKind.ImportDecl) {
			let fromSource: string[] = [];
			for (let k = 0; k < s.importNames.length; k += 1) {
				const alias = k < s.importAliases.length ? s.importAliases[k] : "";
				const local = alias != "" ? alias : s.importNames[k];
				imported.push(local);
				fromSource.push(local);
			}
			importSources.push(importKey(file, s.importSource));
			importNames.push(fromSource);
			continue;
		}
		let decl = s;
		if (s.kind == NodeKind.ExportDecl) decl = s.exportedDecl;
		if (decl.kind == NodeKind.VariableDecl || decl.kind == NodeKind.DestructuringDecl) {
			varJobs.push(jobRoots.length as int32);
			jobRoots.push([decl]);
			continue;
		}
		if (isStatementWithEffects(decl.kind)) sideEffects = true;
		if (decl.kind != NodeKind.FunctionDecl ||
			!isComponentName(decl.fnName) ||
			decl.fnReturnType != "NeonNode" ||
			decl.fnFlags.indexOf("gen:") >= 0 ||
			decl.params.length > 1 ||
			(decl.params.length == 1 && !isPlainParam(decl.params[0]))) {
			continue;
		}
		const body: Node[] = decl.fnBody.statements;
		let setup: Node[] = [];
		let template: Node[] = [];
		let extractable = decl.fnFlags == "" && body.length > 0;
		if (extractable) {
			const last = body[body.length - 1];
			extractable = last.kind == NodeKind.ReturnStmt;
			if (extractable) {
				const arg = last.argument;
				extractable = arg !== null && (arg as Node).kind != NodeKind.Identifier;
				if (extractable) template.push(arg as Node);
			}
		}
		for (let b = 0; b < body.length - (extractable ? 1 : 0); b += 1) setup.push(body[b]);

		let names: string[] = [];
		let lets: string[] = [];
		if (decl.params.length == 1) names.push(decl.params[0]);
		for (const b of setup) {
			if (b.kind == NodeKind.VariableDecl) {
				names.push(b.declName);
				if (b.declKind != DeclKind.Const) lets.push(b.declName);
			} else if (b.kind == NodeKind.FunctionDecl) {
				names.push(b.fnName);
			} else if (b.kind == NodeKind.DestructuringDecl) {
				let pattern: Node[] = [b.destrPattern];
				while (pattern.length > 0) {
					const p = pattern.pop() as Node;
					if (p.kind == NodeKind.Identifier) {
						names.push(p.name);
						if (!b.destrIsConst) lets.push(p.name);
					}
					if (p.kind == NodeKind.ObjectPattern) {
						for (const prop of p.patternProps) pattern.push(prop);
					} else if (p.kind == NodeKind.ObjectPatternProp) {
						pattern.push(p.propAlias);
					} else if (p.kind == NodeKind.ArrayPattern) {
						for (const element of p.patternElements) pattern.push(element);
					}
				}
			}
		}
		let signalAt: int32[] = [];
		let signalJob: int32[] = [];
		for (let b = 0; b < setup.length; b += 1) {
			const st = setup[b];
			if (st.kind != NodeKind.DestructuringDecl) continue;
			const pattern = st.destrPattern;
			const made = st.destrInit;
			if (pattern.kind != NodeKind.ArrayPattern || made.kind != NodeKind.CallExpr) continue;
			if (pattern.hasRestElement || pattern.patternElements.length != 2) continue;
			if (pattern.patternElements[0].kind != NodeKind.Identifier ||
				pattern.patternElements[1].kind != NodeKind.Identifier) {
				continue;
			}
			const maker = made.callee;
			if (maker.kind != NodeKind.Identifier || maker.name != "createSignal") continue;
			signalAt.push(b as int32);
			signalJob.push(jobRoots.length as int32);
			jobRoots.push([made]);
		}
		stateAt.push(signalAt);
		stateJob.push(signalJob);
		compAt.push(i as int32);
		setupJob.push(jobRoots.length as int32);
		jobRoots.push(setup);
		if (extractable) {
			tmplJob.push(jobRoots.length as int32);
			jobRoots.push(template);
		} else {
			tmplJob.push(-1 as int32);
		}
		declared.push(names);
		mutable.push(lets);
	}
	if (compAt.length == 0 && define("hcr") == "") return mod;

	let jobSig: string[] = [];
	let jobNames: string[][] = [];
	let jobTags: string[][] = [];
	let jobReturns: int32[] = [];
	let jobCalls: boolean[] = [];
	for (const roots of jobRoots) {
		let sig = "";
		let names: string[] = [];
		let tags: string[] = [];
		let returns = 0 as int32;
		let calls = false;
		let stack: Node[] = [];
		let depth: int32[] = [];
		for (let r = roots.length - 1; r >= 0; r -= 1) {
			stack.push(roots[r]);
			depth.push(0 as int32);
		}
		while (stack.length > 0) {
			const m = stack.pop() as Node;
			const d = depth.pop() as int32;
			sig = sig + "|" + m.kind.toString();
			if (m.kind == NodeKind.Identifier) {
				sig = sig + ":" + m.name;
				names.push(m.name);
			} else if (m.kind == NodeKind.StringLiteral) {
				sig = sig + ":" + stringValue(m);
			} else if (m.kind == NodeKind.NumberLiteral) {
				const n = isFloatLiteral(m) ? floatValue(m).toString() : intValue(m).toString();
				sig = sig + ":" + n;
			} else if (m.kind == NodeKind.BooleanLiteral) {
				sig = sig + ":" + (m.boolValue ? "true" : "false");
			} else if (m.kind == NodeKind.MemberExpr) {
				sig = sig + ":" + m.property;
			} else if (m.kind == NodeKind.BinaryExpr) {
				sig = sig + ":" + m.operator;
			} else if (m.kind == NodeKind.UnaryExpr) {
				sig = sig + ":" + m.unaryOp;
			} else if (m.kind == NodeKind.UpdateExpr) {
				sig = sig + ":" + m.updateOp;
			} else if (m.kind == NodeKind.VariableDecl) {
				sig = sig + ":" + m.declName + ":" + m.declType;
			} else if (m.kind == NodeKind.ArrowFunction) {
				sig = sig + ":" + m.arrowParams.join(",") + ":" + m.arrowParamTypes.join(",") +
					":" + m.arrowReturnType;
			} else if (m.kind == NodeKind.FunctionDecl) {
				sig = sig + ":" + m.fnName + ":" + m.params.join(",") + ":" +
					m.fnParamTypes.join(",") + ":" + m.fnReturnType;
			} else if (m.kind == NodeKind.TypeAssertion) {
				sig = sig + ":" + m.asType;
			} else if (m.kind == NodeKind.ObjectLiteral) {
				sig = sig + ":" + m.keys.join(",");
			} else if (m.kind == NodeKind.ForOfStmt) {
				sig = sig + ":" + m.forOfBinding;
			} else if (m.kind == NodeKind.ObjectPatternProp) {
				sig = sig + ":" + m.propKey;
			} else if (m.kind == NodeKind.JSXElement) {
				sig = sig + ":" + m.jsxTag;
				tags.push(m.jsxTag);
			} else if (m.kind == NodeKind.JSXText) {
				sig = sig + ":" + m.jsxText;
			} else if (m.kind == NodeKind.JSXAttribute) {
				sig = sig + ":" + m.jsxAttrName;
			}
			if (d == 0 && m.kind == NodeKind.ReturnStmt) returns += 1;
			if (d == 0 && (m.kind == NodeKind.CallExpr || m.kind == NodeKind.NewExpr ||
				m.kind == NodeKind.AwaitExpr)) {
				calls = true;
			}
			const inner = m.kind == NodeKind.ArrowFunction || m.kind == NodeKind.FunctionExpr ||
				m.kind == NodeKind.FunctionDecl ? d + 1 : d;
			const k = childCount(m);
			for (let i = k - 1; i >= 0; i -= 1) {
				stack.push(childAt(m, i));
				depth.push(inner as int32);
			}
		}
		jobSig.push(sig);
		jobNames.push(names);
		jobTags.push(tags);
		jobReturns.push(returns);
		jobCalls.push(calls);
	}
	for (const v of varJobs) {
		if (jobCalls[v]) sideEffects = true;
	}

	let out: Node[] = [];
	let tail: Node[] = [];
	let dependents: Node[] = [];
	let sourceIds: Node[][] = [];
	for (const source of importSources) sourceIds.push([]);
	for (let i = 0; i < stmts.length; i += 1) {
		const s = stmts[i];
		const c = compAt.indexOf(i as int32);
		if (c < 0) {
			out.push(s);
			continue;
		}
		let decl = s;
		if (s.kind == NodeKind.ExportDecl) decl = s.exportedDecl;
		const L = decl.line;
		const C = decl.column;
		const name = decl.fnName;
		const hasProps = decl.params.length == 1;
		const id = name + "|" + (hasProps ? decl.fnParamTypes[0] : "");
		const tid = name + "#template";
		const bodyName = "__refreshBody_" + name;
		const sigName = "__refreshSig_" + name;
		const tmplName = "__refreshTmpl_" + name;
		const tmplSigName = "__refreshTmplSig_" + name;
		const setupName = "__refreshSetup_" + name;
		const sj = setupJob[c];
		const tj = tmplJob[c];

		let captures: string[] = [];
		let extract = tj >= 0 && jobReturns[sj] == 0;
		if (extract) {
			for (const n of declared[c]) {
				const read = jobNames[tj].indexOf(n) >= 0 || jobTags[tj].indexOf(n) >= 0;
				if (read && captures.indexOf(n) < 0) captures.push(n);
			}
			if (intersects(captures, mutable[c])) extract = false;
		}

		const head = decl.params.join(",") + "|" + decl.fnParamTypes.join(",") + "|" +
			decl.fnReturnType;
		let sig = head + jobSig[sj];
		let tmplSig = "";
		if (extract) {
			sig = sig + "|captures:" + captures.join(",");
			tmplSig = captures.join(",") + jobSig[tj];
			if (intersects(jobNames[tj], imported) || intersects(jobTags[tj], imported)) {
				dependents.push({ kind: NodeKind.StringLiteral, line: L, column: C, value: tid });
			}
			for (let k = 0; k < importSources.length; k += 1) {
				if (importSources[k] != "" && intersects(jobNames[tj], importNames[k])) {
					const read: Node = {
						kind: NodeKind.StringLiteral,
						line: L,
						column: C,
						value: tid,
					};
					sourceIds[k].push(read);
				}
			}
		} else {
			if (tj >= 0) sig = sig + jobSig[tj];
			const usesImports = intersects(jobNames[sj], imported) ||
				(tj >= 0 && intersects(jobNames[tj], imported)) ||
				(tj >= 0 && intersects(jobTags[tj], imported));
			if (usesImports) {
				dependents.push({ kind: NodeKind.StringLiteral, line: L, column: C, value: id });
			}
			for (let k = 0; k < importSources.length; k += 1) {
				const reads = intersects(jobNames[sj], importNames[k]) ||
					(tj >= 0 && intersects(jobNames[tj], importNames[k]));
				if (importSources[k] != "" && reads) {
					const read: Node = {
						kind: NodeKind.StringLiteral,
						line: L,
						column: C,
						value: id,
					};
					sourceIds[k].push(read);
				}
			}
		}

		const written: Node[] = decl.fnBody.statements;
		let original: Node[] = [];
		for (let b = 0; b < written.length; b += 1) {
			const st = written[b];
			original.push(st);
			const at = stateAt[c].indexOf(b as int32);
			if (at < 0) continue;
			const made = st.destrInit;
			const pair = st.destrPattern.patternElements;
			const get = pair[0].name;
			original.push({ kind: NodeKind.ExprStmt, line: st.line, column: st.column, expr: {
				kind: NodeKind.CallExpr,
				line: st.line,
				column: st.column,
				callee: { kind: NodeKind.Identifier, line: st.line, column: st.column, name: "refreshState" },
				arguments: [
					{
						kind: NodeKind.StringLiteral,
						line: st.line,
						column: st.column,
						value: get + "|" + made.typeArg + jobSig[stateJob[c][at]],
					},
					{ kind: NodeKind.Identifier, line: st.line, column: st.column, name: get },
					{ kind: NodeKind.Identifier, line: st.line, column: st.column, name: pair[1].name },
				],
			} });
		}
		let bodyBlock: Node = { kind: NodeKind.BlockStmt, line: L, column: C, statements: original };
		if (extract) {
			let reads: Node[] = [];
			let fields: Node[] = [];
			let keys: string[] = [];
			for (const n of captures) {
				reads.push({
					kind: NodeKind.VariableDecl,
					line: L,
					column: C,
					declName: n,
					declType: "",
					initializer: {
						kind: NodeKind.MemberExpr,
						line: L,
						column: C,
						object: {
							kind: NodeKind.Identifier,
							line: L,
							column: C,
							name: "__refreshEnv",
						},
						property: n,
						isOptional: false,
					},
					declKind: DeclKind.Const,
					nameLocation: { line: L, column: C },
				});
				fields.push({ kind: NodeKind.Identifier, line: L, column: C, name: n });
				keys.push(n);
			}
			if (captures.length == 0) {
				fields.push({ kind: NodeKind.BooleanLiteral, line: L, column: C, boolValue: true });
				keys.push("__refreshUnit");
			}
			let keyLocations = [decl.nameLocation];
			while (keyLocations.length < keys.length) keyLocations.push(decl.nameLocation);
			reads.push(original[original.length - 1]);
			out.push({
				kind: NodeKind.FunctionDecl,
				line: L,
				column: C,
				fnName: tmplName,
				params: ["__refreshEnv"],
				fnParamTypes: ["E"],
				fnBody: { kind: NodeKind.BlockStmt, line: L, column: C, statements: reads },
				fnFlags: "gen:E",
				fnReturnType: "NeonNode",
				fnDefaults: [],
				nativeName: "",
				nameLocation: { line: L, column: C },
			});
			let setupStmts: Node[] = [];
			for (let b = 0; b < original.length - 1; b += 1) setupStmts.push(original[b]);
			setupStmts.push({
				kind: NodeKind.ReturnStmt,
				line: L,
				column: C,
				argument: {
					kind: NodeKind.ObjectLiteral,
					line: L,
					column: C,
					properties: fields,
					keys: keys,
					keyLocations: keyLocations,
				},
			});
			out.push({
				kind: NodeKind.FunctionDecl,
				line: L,
				column: C,
				fnName: setupName,
				params: decl.params,
				fnParamTypes: decl.fnParamTypes,
				fnBody: { kind: NodeKind.BlockStmt, line: L, column: C, statements: setupStmts },
				fnFlags: "",
				fnReturnType: "",
				fnDefaults: [],
				nativeName: "",
				nameLocation: { line: L, column: C },
			});
			out.push({
				kind: NodeKind.FunctionDecl,
				line: L,
				column: C,
				fnName: tmplSigName,
				params: [],
				fnParamTypes: [],
				fnBody: { kind: NodeKind.BlockStmt, line: L, column: C, statements: [{
					kind: NodeKind.ReturnStmt,
					line: L,
					column: C,
					argument: { kind: NodeKind.StringLiteral, line: L, column: C, value: tmplSig },
				}] },
				fnFlags: "",
				fnReturnType: "string",
				fnDefaults: [],
				nativeName: "",
				nameLocation: { line: L, column: C },
			});
			let setupArgs: Node[] = [];
			if (hasProps) {
				const props = decl.params[0];
				setupArgs.push({ kind: NodeKind.Identifier, line: L, column: C, name: props });
			}
			bodyBlock = { kind: NodeKind.BlockStmt, line: L, column: C, statements: [{
				kind: NodeKind.ReturnStmt,
				line: L,
				column: C,
				argument: {
					kind: NodeKind.CallExpr,
					line: L,
					column: C,
					callee: {
						kind: NodeKind.Identifier,
						line: L,
						column: C,
						name: "refreshRegion",
					},
					arguments: [
						{ kind: NodeKind.StringLiteral, line: L, column: C, value: file },
						{ kind: NodeKind.StringLiteral, line: L, column: C, value: tid },
						{ kind: NodeKind.Identifier, line: L, column: C, name: tmplName },
						{ kind: NodeKind.Identifier, line: L, column: C, name: tmplSigName },
						{
							kind: NodeKind.CallExpr,
							line: L,
							column: C,
							callee: {
								kind: NodeKind.Identifier,
								line: L,
								column: C,
								name: setupName,
							},
							arguments: setupArgs,
						},
					],
				},
			}] };
			tail.push({ kind: NodeKind.ExprStmt, line: L, column: C, expr: {
				kind: NodeKind.CallExpr,
				line: L,
				column: C,
				callee: {
					kind: NodeKind.Identifier,
					line: L,
					column: C,
					name: hasProps ? "refreshTemplate" : "refreshTemplate0",
				},
				arguments: [
					{ kind: NodeKind.StringLiteral, line: L, column: C, value: file },
					{ kind: NodeKind.StringLiteral, line: L, column: C, value: tid },
					{ kind: NodeKind.Identifier, line: L, column: C, name: tmplName },
					{ kind: NodeKind.Identifier, line: L, column: C, name: tmplSigName },
					{ kind: NodeKind.Identifier, line: L, column: C, name: setupName },
				],
			} });
		}

		out.push({
			kind: NodeKind.FunctionDecl,
			line: L,
			column: C,
			fnName: bodyName,
			params: decl.params,
			fnParamTypes: decl.fnParamTypes,
			fnBody: bodyBlock,
			fnFlags: decl.fnFlags,
			fnReturnType: decl.fnReturnType,
			fnDefaults: [],
			nativeName: "",
			nameLocation: { line: L, column: C },
		});
		out.push({
			kind: NodeKind.FunctionDecl,
			line: L,
			column: C,
			fnName: sigName,
			params: [],
			fnParamTypes: [],
			fnBody: { kind: NodeKind.BlockStmt, line: L, column: C, statements: [{
				kind: NodeKind.ReturnStmt,
				line: L,
				column: C,
				argument: { kind: NodeKind.StringLiteral, line: L, column: C, value: sig },
			}] },
			fnFlags: "",
			fnReturnType: "string",
			fnDefaults: [],
			nativeName: "",
			nameLocation: { line: L, column: C },
		});
		let mountArgs: Node[] = [
			{ kind: NodeKind.StringLiteral, line: L, column: C, value: file },
			{ kind: NodeKind.StringLiteral, line: L, column: C, value: id },
			{ kind: NodeKind.Identifier, line: L, column: C, name: bodyName },
			{ kind: NodeKind.Identifier, line: L, column: C, name: sigName },
		];
		if (hasProps) {
			const props = decl.params[0];
			mountArgs.push({ kind: NodeKind.Identifier, line: L, column: C, name: props });
		}
		decl.fnBody = { kind: NodeKind.BlockStmt, line: L, column: C, statements: [{
			kind: NodeKind.ReturnStmt,
			line: L,
			column: C,
			argument: {
				kind: NodeKind.CallExpr,
				line: L,
				column: C,
				callee: {
					kind: NodeKind.Identifier,
					line: L,
					column: C,
					name: hasProps ? "refreshBoundary" : "refreshBoundary0",
				},
				arguments: mountArgs,
			},
		}] };
		out.push(s);
		tail.push({ kind: NodeKind.ExprStmt, line: L, column: C, expr: {
			kind: NodeKind.CallExpr,
			line: L,
			column: C,
			callee: {
				kind: NodeKind.Identifier,
				line: L,
				column: C,
				name: hasProps ? "refreshComponent" : "refreshComponent0",
			},
			arguments: [
				{ kind: NodeKind.StringLiteral, line: L, column: C, value: file },
				{ kind: NodeKind.StringLiteral, line: L, column: C, value: id },
				{ kind: NodeKind.Identifier, line: L, column: C, name: bodyName },
				{ kind: NodeKind.Identifier, line: L, column: C, name: sigName },
			],
		} });
	}

	const components = compAt.length > 0;
	for (const t of tail) out.push(t);
	if (components) {
		out.push({ kind: NodeKind.ExprStmt, line: ML, column: MC, expr: {
			kind: NodeKind.CallExpr,
			line: ML,
			column: MC,
			callee: { kind: NodeKind.Identifier, line: ML, column: MC, name: "refreshModuleEval" },
			arguments: [
				{ kind: NodeKind.StringLiteral, line: ML, column: MC, value: file },
				{ kind: NodeKind.StringLiteral, line: ML, column: MC, value: jobSig[0] },
				{ kind: NodeKind.ArrayLiteral, line: ML, column: MC, elements: dependents },
			],
		} });
	}
	if (define("hcr") != "") {
		for (let k = 0; k < importSources.length; k += 1) {
			if (sourceIds[k].length == 0) continue;
			out.push({ kind: NodeKind.ExprStmt, line: ML, column: MC, expr: {
				kind: NodeKind.CallExpr,
				line: ML,
				column: MC,
				callee: { kind: NodeKind.Identifier, line: ML, column: MC, name: "refreshImports" },
				arguments: [
					{ kind: NodeKind.StringLiteral, line: ML, column: MC, value: file },
					{ kind: NodeKind.StringLiteral, line: ML, column: MC, value: importSources[k] },
					{ kind: NodeKind.ArrayLiteral, line: ML, column: MC, elements: sourceIds[k] },
				],
			} });
		}
		let reloaded: Node[] = [];
		if (components) {
			reloaded.push({ kind: NodeKind.ExprStmt, line: ML, column: MC, expr: {
				kind: NodeKind.CallExpr,
				line: ML,
				column: MC,
				callee: { kind: NodeKind.Identifier, line: ML, column: MC, name: "refreshModule" },
				arguments: [{ kind: NodeKind.StringLiteral, line: ML, column: MC, value: file }],
			} });
		}
		reloaded.push({ kind: NodeKind.ExprStmt, line: ML, column: MC, expr: {
			kind: NodeKind.CallExpr,
			line: ML,
			column: MC,
			callee: { kind: NodeKind.Identifier, line: ML, column: MC, name: "refreshDependency" },
			arguments: [{
				kind: NodeKind.StringLiteral,
				line: ML,
				column: MC,
				value: moduleKey(file),
			}],
		} });
		out.push({
			kind: NodeKind.DecoratedDecl,
			line: ML,
			column: MC,
			decorators: [{
				kind: NodeKind.MacroInvocation,
				line: ML,
				column: MC,
				macroName: "afterReload",
				macroArgs: [],
				macroHasParens: false,
			}],
			decoratedNode: {
				kind: NodeKind.FunctionDecl,
				line: ML,
				column: MC,
				fnName: "__refreshAfterReload",
				params: [],
				fnParamTypes: [],
				fnBody: { kind: NodeKind.BlockStmt, line: ML, column: MC, statements: reloaded },
				fnFlags: "",
				fnReturnType: "void",
				fnDefaults: [],
				nativeName: "",
				nameLocation: { line: ML, column: MC },
			},
		});
	}
	when (js) {
		if (components && !sideEffects) {
			out.push({ kind: NodeKind.ExprStmt, line: ML, column: MC, expr: {
				kind: NodeKind.MacroInvocation,
				line: ML,
				column: MC,
				macroName: "emit",
				macroArgs: [{
					kind: NodeKind.StringLiteral,
					line: ML,
					column: MC,
					value: "if (import.meta.hot) import.meta.hot.accept();",
				}],
				macroHasParens: true,
			} });
		}
	}
	return { kind: NodeKind.Program, line: ML, column: MC, programStmts: out };
}
