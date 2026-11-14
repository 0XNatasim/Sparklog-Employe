import { describe, expect, it } from "vitest";
import { APPLICATION_ROLES, authorizationFor } from "./authorization-matrix";
import {
  MANAGER_NAV, MANAGER_NAV_ITEMS, MANAGER_PAGES, OLD_PATHS, canOpenNavItem, findNavItem, firstAllowedPath,
  hasNestedTabs, legacySectionTarget, nestedTabs, oldPathTarget, resolveTab, tabPath, visibleManagerNav, visibleTabs,
} from "./manager-nav";
import { GRANTABLE_ADMIN_SECTIONS } from "./roles";

const ids = (role, adminSections) => visibleManagerNav(role, adminSections).flatMap((g) => g.items.map((i) => i.id));
const entries = MANAGER_NAV.flatMap((group) => group.items);
const byId = (id) => MANAGER_NAV_ITEMS.find((item) => item.id === id);
const sourceOf = (t) => (t.from ? byId(t.from) : t);
const ROLES = ["employee", "foreman", "subcontractor_1", "manager", "owner"];
const ADMIN_GRANTS = [[], ...GRANTABLE_ADMIN_SECTIONS.map((s) => [s]), [...GRANTABLE_ADMIN_SECTIONS]];
const personas = [...ROLES.map((role) => [role, []]), ...ADMIN_GRANTS.map((grants) => ["admin", grants])];

describe("Gestion menu", () => {
  it("has unique ids and paths", () => {
    expect(new Set(MANAGER_NAV_ITEMS.map((i) => i.id)).size).toBe(MANAGER_NAV_ITEMS.length);
    expect(new Set(MANAGER_NAV_ITEMS.map((i) => i.path)).size).toBe(MANAGER_NAV_ITEMS.length);
  });


  it("Notes has one tab, Foreman (0134), for the managers only (personal notes are on side 2)", () => {
    const notes = byId("notes");
    expect(notes.tabs.map((t) => t.key)).toEqual(["foreman"]);
    expect(visibleTabs(notes, "manager", []).map((t) => t.key)).toEqual(["foreman"]);
    for (const role of ["employee", "foreman", "subcontractor_1"]) expect(visibleTabs(notes, role, [])).toEqual([]);
    expect(visibleTabs(notes, "admin", [...GRANTABLE_ADMIN_SECTIONS])).toEqual([]);
  });



  it("gives every tab the access rule of the page it comes from, for every role and grant", () => {
    for (const [role, grants] of personas) {
      for (const entry of entries) {
        for (const t of entry.tabs || []) {
          const expected = canOpenNavItem(role, grants, sourceOf(t));
          expect(visibleTabs(entry, role, grants).some((v) => v.key === t.key), `${role}[${grants}] ${entry.id}:${t.key}`).toBe(expected);
        }
        const anyTab = entry.tabs ? entry.tabs.some((t) => canOpenNavItem(role, grants, sourceOf(t))) : canOpenNavItem(role, grants, byId(entry.id));
        expect(canOpenNavItem(role, grants, entry), `${role}[${grants}] ${entry.id}`).toBe(anyTab);
      }
    }
  });


  it.each(["employee", "subcontractor_1", "admin"])("shows nothing to %s without a grant", (role) => {
    expect(ids(role, [])).toEqual([]);
    expect(firstAllowedPath(role, [])).toBeNull();
  });


  it("agrees with the authorization matrix for every role and grant", () => {
    for (const role of APPLICATION_ROLES) {
      for (const section of GRANTABLE_ADMIN_SECTIONS) {
        const permissions = authorizationFor({ role, adminSections: [section] });
        for (const item of MANAGER_NAV_ITEMS.filter((i) => i.grant === section)) {
          expect(canOpenNavItem(role, [section], item), `${role}:${item.id}`).toBe(permissions.managementSections[section]);
        }
      }
    }
  });



});

describe("old paths (the V2 menu, removed in V2.4.186)", () => {
  const menuPaths = new Set(entries.map((item) => item.path));

  it("sends every former page to a menu entry, on a tab with the same access rule", () => {
    for (const page of MANAGER_PAGES) {
      if (menuPaths.has(page.path)) {
        expect(OLD_PATHS[page.path], page.path).toBeUndefined();
        continue;
      }
      const eq = OLD_PATHS[page.path];
      expect(eq, page.path).toBeTruthy();
      const entry = entries.find((item) => item.path === eq.path);
      const target = entry?.tabs?.find((t) => t.key === eq.tab);
      expect(target, page.path).toBeTruthy();
      expect(sourceOf(target).grant ?? null, page.path).toBe(page.grant ?? null);
    }
    for (const [path, eq] of Object.entries(OLD_PATHS)) {
      const entry = entries.find((item) => item.path === eq.path);
      expect(entry?.tabs?.some((t) => t.key === eq.tab), path).toBe(true);
    }
  });


  it("leaves current paths alone", () => {
    expect(oldPathTarget("live", "")).toBeNull();
    expect(oldPathTarget("v3/time", "?tab=timesheets")).toBeNull();
    expect(oldPathTarget("nope", "")).toBeNull();
  });
});

describe("legacy ?section= links", () => {
  it.each([
    ["?section=timesheet", "v3/time?tab=timesheets"],
    ["?section=live", "live"],
    ["?section=meals&job=abc", "todo?job=abc&filter=meals&tab=receipts"],
    ["?section=overtime&job=1", "todo?job=1&filter=overtime&tab=receipts"],
    ["?section=parking", "todo?filter=parking&tab=receipts"],
    ["?section=timesheet&job=9", "v3/time?job=9&tab=timesheets"],
  ])("%s → %s", (search, target) => {
    expect(legacySectionTarget(search)).toBe(target);
  });

  it("ignores unknown or missing sections", () => {
    expect(legacySectionTarget("")).toBeNull();
    expect(legacySectionTarget("?section=bogus")).toBeNull();
  });
});

describe("tabs nested in the sidebar (4 tabs or more)", () => {


  it("keeps horizontal tabs (no children) for pages of 3 tabs or fewer", () => {
    expect(nestedTabs(byId("v3-time"), "manager", [])).toEqual([]);
    expect(nestedTabs(byId("v3-team"), "manager", [])).toEqual([]);
  });

  it("links each child to its ?tab= and resolves it back", () => {
    for (const item of entries.filter(hasNestedTabs)) {
      for (const child of nestedTabs(item, "owner", [])) {
        const url = new URL(tabPath(item, child.key), "http://x");
        expect(url.pathname).toBe(`/manager/${item.path}`);
        expect(resolveTab(item, "owner", [], url.searchParams.get("tab"))).toBe(child.key);
      }
    }
  });
});

describe("sub-pages opened from a button", () => {
  it("resolves Inventaire › Minimums for the title and the guard, manager / owner only, and keeps it out of the menu", () => {
    const page = findNavItem("inventory/minimums");
    expect(page).toMatchObject({ id: "inventory-minimums", parent: "inventory" });
    expect(MANAGER_NAV.flatMap((group) => group.items).some((item) => item.path === "inventory/minimums")).toBe(false);
    expect(canOpenNavItem("manager", [], page)).toBe(true);
    expect(canOpenNavItem("owner", [], page)).toBe(true);
    for (const role of ["employee", "subcontractor_1", "admin"]) expect(canOpenNavItem(role, [...GRANTABLE_ADMIN_SECTIONS], page), role).toBe(false);
  });
});

