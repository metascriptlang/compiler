// msc org — organization management.
//
// Usage:
//   msc org create <name>              — create an organization
//   msc org invite <org> <username>    — add a member
//   msc org remove <org> <username>    — remove a member
//   msc org list                       — list your organizations
//   msc org members <org>              — list org members
//   msc org role <org> <user> <role>   — change member role (owner|member)

import { fetch } from "std/http/client";
import { createHeaders, setHeader } from "std/http/headers";
import { parseJson, JsonValue, JsonKind } from "std/core/json";
import { loadToken } from "./login";
import { registryBaseUrl } from "./registry";
import { error as errStyle, bold, green, cyan, dim } from "../../utils/color";

const ORG_API_BASE = registryBaseUrl();

function getStr(obj: JsonValue, field: string): string {
	if (obj === null || obj.kind !== JsonKind.Object) return "";
	let i = 0;
	while (i < obj.keys.length) {
		if (obj.keys[i] === field && i < obj.values.length) {
			const v = obj.values[i];
			if (v !== null && v.kind === JsonKind.String) return v.strVal;
		}
		i = i + 1;
	}
	return "";
}

function getArray(obj: JsonValue, field: string): JsonValue[] {
	if (obj === null || obj.kind !== JsonKind.Object) return [];
	let i = 0;
	while (i < obj.keys.length) {
		if (obj.keys[i] === field && i < obj.values.length) {
			const v = obj.values[i];
			if (v !== null && v.kind === JsonKind.Array) return v.items;
		}
		i = i + 1;
	}
	return [];
}

function authHeaders(): { headers: any, ok: boolean } {
	const token = loadToken();
	if (token === "") {
		console.log(`${errStyle("error")}: not logged in — run ${cyan("msc login")} first`);
		return { headers: null, ok: false };
	}
	const h = createHeaders();
	setHeader(h, "authorization", "Bearer " + token);
	setHeader(h, "content-type", "application/json");
	return { headers: h, ok: true };
}

export function cmdOrg(args: string[]): boolean {
	if (args.length === 0) {
		printUsage();
		return false;
	}

	const sub = args[0];
	match (sub) {
		"create" => { return orgCreate(args); },
		"invite" => { return orgInvite(args); },
		"remove" => { return orgRemove(args); },
		"list" => { return orgList(); },
		"members" => { return orgMembers(args); },
		"role" => { return orgRole(args); },
		_ => {
			console.log(`${errStyle("error")}: unknown org command: ${sub}`);
			printUsage();
			return false;
		},
	};
}

function printUsage(): void {
	console.log("usage: msc org <command>");
	console.log("");
	console.log("commands:");
	console.log("  create <name>              create an organization");
	console.log("  invite <org> <username>    add a member");
	console.log("  remove <org> <username>    remove a member");
	console.log("  list                       list your organizations");
	console.log("  members <org>              list org members");
	console.log("  role <org> <user> <role>   change member role");
}

function orgCreate(args: string[]): boolean {
	if (args.length < 2) {
		console.log(`${errStyle("error")}: usage: msc org create <name>`);
		return false;
	}
	const name = args[1];
	const auth = authHeaders();
	if (!auth.ok) return false;

	const body = "{\"name\":" + "\"" + name + "\"}";
	const fetchResult = fetch(ORG_API_BASE + "/orgs", {
		method: "POST",
		body: body,
		headers: auth.headers,
	});
	if (!fetchResult.ok) { console.log(`${errStyle("error")}: failed to reach registry`); return false; }
	const resp = fetchResult.value;

	if (resp.status === 201) {
		console.log(`${green("created")} organization ${cyan("@" + name)}`);
		return true;
	}

	const parsed = parseJson(resp.body);
	const errMsg = parsed.ok ? getStr(parsed.value, "error") : resp.body;
	console.log(`${errStyle("error")}: ${errMsg}`);
	return false;
}

function orgInvite(args: string[]): boolean {
	if (args.length < 3) {
		console.log(`${errStyle("error")}: usage: msc org invite <org> <username>`);
		return false;
	}
	const orgName = args[1];
	const username = args[2];
	const auth = authHeaders();
	if (!auth.ok) return false;

	const body = "{\"username\":\"" + username + "\"}";
	const fetchResult = fetch(ORG_API_BASE + "/orgs/" + orgName + "/members", {
		method: "POST",
		body: body,
		headers: auth.headers,
	});
	if (!fetchResult.ok) { console.log(`${errStyle("error")}: failed to reach registry`); return false; }
	const resp = fetchResult.value;

	if (resp.status === 201) {
		console.log(`${green("added")} ${cyan(username)} to ${cyan("@" + orgName)}`);
		return true;
	}

	const parsed = parseJson(resp.body);
	const errMsg = parsed.ok ? getStr(parsed.value, "error") : resp.body;
	console.log(`${errStyle("error")}: ${errMsg}`);
	return false;
}

function orgRemove(args: string[]): boolean {
	if (args.length < 3) {
		console.log(`${errStyle("error")}: usage: msc org remove <org> <username>`);
		return false;
	}
	const orgName = args[1];
	const username = args[2];
	const auth = authHeaders();
	if (!auth.ok) return false;

	const fetchResult = fetch(ORG_API_BASE + "/orgs/" + orgName + "/members/" + username, {
		method: "DELETE",
		headers: auth.headers,
	});
	if (!fetchResult.ok) { console.log(`${errStyle("error")}: failed to reach registry`); return false; }
	const resp = fetchResult.value;

	if (resp.status === 200) {
		console.log(`${green("removed")} ${cyan(username)} from ${cyan("@" + orgName)}`);
		return true;
	}

	const parsed = parseJson(resp.body);
	const errMsg = parsed.ok ? getStr(parsed.value, "error") : resp.body;
	console.log(`${errStyle("error")}: ${errMsg}`);
	return false;
}

function orgList(): boolean {
	const auth = authHeaders();
	if (!auth.ok) return false;

	const fetchResult = fetch(ORG_API_BASE + "/orgs", {
		method: "GET",
		headers: auth.headers,
	});
	if (!fetchResult.ok) { console.log(`${errStyle("error")}: failed to reach registry`); return false; }
	const resp = fetchResult.value;

	if (resp.status !== 200) {
		console.log(`${errStyle("error")}: failed to list organizations`);
		return false;
	}

	const parsed = parseJson(resp.body);
	if (!parsed.ok) {
		console.log(`${errStyle("error")}: invalid response`);
		return false;
	}

	const orgs = getArray(parsed.value, "organizations");
	if (orgs.length === 0) {
		console.log("no organizations — create one with " + cyan("msc org create <name>"));
		return true;
	}

	let i = 0;
	while (i < orgs.length) {
		const name = getStr(orgs[i], "orgName");
		const role = getStr(orgs[i], "role");
		console.log(`  ${cyan("@" + name)}  ${dim(role)}`);
		i = i + 1;
	}
	return true;
}

function orgMembers(args: string[]): boolean {
	if (args.length < 2) {
		console.log(`${errStyle("error")}: usage: msc org members <org>`);
		return false;
	}
	const orgName = args[1];

	const fetchResult = fetch(ORG_API_BASE + "/orgs/" + orgName, { method: "GET" });
	if (!fetchResult.ok) { console.log(`${errStyle("error")}: failed to reach registry`); return false; }
	const resp = fetchResult.value;
	if (resp.status === 404) {
		console.log(`${errStyle("error")}: organization not found: @${orgName}`);
		return false;
	}
	if (resp.status !== 200) {
		console.log(`${errStyle("error")}: failed to fetch org`);
		return false;
	}

	const parsed = parseJson(resp.body);
	if (!parsed.ok) {
		console.log(`${errStyle("error")}: invalid response`);
		return false;
	}

	const members = getArray(parsed.value, "members");
	console.log(`${bold("@" + orgName)} — ${members.length.toString()} member(s)`);
	let i = 0;
	while (i < members.length) {
		const username = getStr(members[i], "username");
		const role = getStr(members[i], "role");
		console.log(`  ${cyan(username)}  ${dim(role)}`);
		i = i + 1;
	}
	return true;
}

function orgRole(args: string[]): boolean {
	if (args.length < 4) {
		console.log(`${errStyle("error")}: usage: msc org role <org> <username> <owner|member>`);
		return false;
	}
	const orgName = args[1];
	const username = args[2];
	const role = args[3];

	if (role !== "owner" && role !== "member") {
		console.log(`${errStyle("error")}: role must be "owner" or "member"`);
		return false;
	}

	const auth = authHeaders();
	if (!auth.ok) return false;

	const body = "{\"role\":\"" + role + "\"}";
	const fetchResult = fetch(ORG_API_BASE + "/orgs/" + orgName + "/members/" + username, {
		method: "PATCH",
		body: body,
		headers: auth.headers,
	});
	if (!fetchResult.ok) { console.log(`${errStyle("error")}: failed to reach registry`); return false; }
	const resp = fetchResult.value;

	if (resp.status === 200) {
		console.log(`${green("updated")} ${cyan(username)} → ${cyan(role)} in ${cyan("@" + orgName)}`);
		return true;
	}

	const parsed = parseJson(resp.body);
	const errMsg = parsed.ok ? getStr(parsed.value, "error") : resp.body;
	console.log(`${errStyle("error")}: ${errMsg}`);
	return false;
}
