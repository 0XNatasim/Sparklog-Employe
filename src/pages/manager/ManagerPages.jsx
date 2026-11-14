import React, { useEffect } from "react";
import { Navigate, useLocation, useNavigate, useSearchParams } from "react-router-dom";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { useAuth } from "@/contexts/AuthContext";
import { useT } from "@/lib/use-t";
import { cn } from "@/lib/utils";
import { MANAGER_NAV_ITEMS, firstAllowedPath, hasNestedTabs, legacySectionTarget, oldPathTarget, resolveTab, tabAlias, visibleTabs } from "@/lib/manager-nav";
import { useSidebarTabs } from "@/components/manager/nav-context";
import { lazyPanel } from "@/components/lazy-panel";

// Each page loads on first visit, so employees never download manager code and a
// manager only fetches the pages they open (each shows its own fallback meanwhile).
const LiveCrew = lazyPanel(() => import("@/components/LiveCrew"));
const TodoInbox = lazyPanel(() => import("@/components/manager/TodoInbox"));
const PresetWorkOrdersManager = lazyPanel(() => import("@/components/PresetWorkOrdersManager"));
const MissingDaysPanel = lazyPanel(() => import("@/components/manager/MissingDaysPanel"));
const UnlockDayManager = lazyPanel(() => import("@/components/UnlockDayManager"));
const AuditLog = lazyPanel(() => import("@/components/AuditLog"));
const EmployeeActivityLog = lazyPanel(() => import("@/components/EmployeeActivityLog"));
const InfraHealthCard = lazyPanel(() => import("@/components/InfraHealthCard"));
const InventoryMinimums = lazyPanel(() => import("@/components/InventoryMinimums"));
const InventoryScreenshotsPanel = lazyPanel(() => import("@/components/InventoryScreenshotsPanel"));
const EmergencyTimesheet = lazyPanel(() => import("@/components/EmergencyTimesheet"));
const NotesPanel = lazyPanel(() => import("@/components/manager/NotesPanel"));
const ForemanReportsPanel = lazyPanel(() => import("@/components/manager/ForemanReportsPanel"));
const ManagerDashboard = lazyPanel(() => import("@/pages/ManagerDashboard"));

// #/manager → first page the user may open; old `?section=` links keep working.
export function ManagerIndex() {
  const { role, adminSections } = useAuth();
  const { search } = useLocation();
  const legacy = legacySectionTarget(search);
  if (legacy) return <Navigate to={`/manager/${legacy}`} replace />;
  const first = firstAllowedPath(role, adminSections);
  return <Navigate to={first ? `/manager/${first}` : "/"} replace />;
}

// An old path (the V2 menu, removed in V2.4.186: a bookmark, an old link) → the page and tab that
// hold it now, keeping the query (employee, day, filter, job…).
export function OldPathRedirect() {
  const { pathname, search } = useLocation();
  const target = oldPathTarget(pathname.replace(/^\/manager\/?/, ""), search);
  return <Navigate to={target ? `/manager/${target}` : "/manager"} replace />;
}

// Setting forms stay readable; tables use the full width.
function Narrow({ children }) {
  return <div className="max-w-3xl">{children}</div>;
}

// Picking an employee opens their timesheet for that day (filters travel in the URL).
export function LivePage() {
  const navigate = useNavigate();
  return (
    <LiveCrew
      onSelectEmployee={(userId, date) => {
        const params = new URLSearchParams({ emp: userId });
        if (date) params.set("date", date);
        params.set("tab", "timesheets");
        navigate(`/manager/v3/time?${params}`);
      }}
    />
  );
}

export const TodoPage = () => <TodoInbox />;

export const InventoryPage = () => <InventoryScreenshotsPanel />;
export const InventoryMinimumsPage = () => <InventoryMinimums />;
export const HealthPage = () => <InfraHealthCard />;
export const EmergencyPage = () => <EmergencyTimesheet />;
export const NotesPage = () => <NotesPanel />;

// ── Avancé › Journal: manager actions · employee activity ───────────────────
export function AuditPage() {
  const t = useT();
  const [params, setParams] = useSearchParams();
  const view = params.get("view") === "employees" ? "employees" : "managers";
  function setView(value) {
    const next = new URLSearchParams(params);
    if (value === "managers") next.delete("view"); else next.set("view", value);
    setParams(next, { replace: true });
  }
  return (
    <Tabs value={view} onValueChange={setView} className="w-full">
      <TabsList>
        <TabsTrigger value="managers">{t("audit.tabs.managers")}</TabsTrigger>
        <TabsTrigger value="employees">{t("audit.tabs.employees")}</TabsTrigger>
      </TabsList>
      <TabsContent value="managers" className="mt-3"><AuditLog /></TabsContent>
      <TabsContent value="employees" className="mt-3"><EmployeeActivityLog /></TabsContent>
    </Tabs>
  );
}

// ── Pages with tabs ─────────────────────────────────────────────────────────
// The active tab lives in the URL (?tab=); a tab this user may not open — or none at all — falls
// back to the first allowed one, and a page with no allowed tab sends back to #/manager. Only the
// active tab is mounted, so a tab loads its data only when it is opened. A page with many tabs
// (hasNestedTabs) also lists them in the sidebar; its horizontal row is hidden only where that sidebar
// is on screen (desktop, menu shown). A phone keeps the row: its menu is a closed drawer.
const navItem = (id) => MANAGER_NAV_ITEMS.find((item) => item.id === id);

function TabbedPage({ itemId, content }) {
  const t = useT();
  const { role, adminSections } = useAuth();
  const [params, setParams] = useSearchParams();
  const item = navItem(itemId);
  const tabs = visibleTabs(item, role, adminSections);
  const requested = params.get("tab");
  const active = resolveTab(item, role, adminSections, requested);
  const nested = hasNestedTabs(item);
  const menuShown = useSidebarTabs();

  // Put the tab actually shown in the URL (replace: Back does not step through the correction).
  useEffect(() => {
    if (!active || requested === active) return;
    const next = new URLSearchParams(params);
    next.set("tab", active);
    // A former tab (« month ») may also choose the view of the tab that replaced it.
    const alias = tabAlias(item, requested);
    if (alias?.tab === active && alias.view) next.set("view", alias.view);
    setParams(next, { replace: true });
  }, [active, requested, params, setParams, item]);

  if (!active) return <Navigate to="/manager" replace />;

  function select(key) {
    const next = new URLSearchParams(params);
    next.set("tab", key);
    setParams(next);
  }

  const Content = content[active];
  return (
    <Tabs value={active} onValueChange={select} className="w-full">
      {tabs.length > 1 && (
        <TabsList className={cn("h-auto max-w-full flex-wrap justify-start", nested && menuShown && "md:hidden")}>
          {tabs.map((tabItem) => <TabsTrigger key={tabItem.key} value={tabItem.key}>{t(tabItem.labelKey)}</TabsTrigger>)}
        </TabsList>
      )}
      <div className={tabs.length > 1 ? cn("mt-3", nested && menuShown && "md:mt-0") : undefined}>{Content ? <Content /> : null}</div>
    </Tabs>
  );
}

const TODO_TABS = { todo: TodoPage, receipts: () => <ManagerDashboard view="receipts" reviewFilters /> };
// Timesheets: cards with the employee's name first, the « Entrées à la main » filter, plain words.
const TIME_TABS = { timesheets: () => <ManagerDashboard view="timesheet" nameFirst manualFilter plainWords />, unlock: () => <Narrow><UnlockDayManager plainWords /></Narrow>, missing: () => <Narrow><MissingDaysPanel /></Narrow> };
const NOTES_TABS = { mine: NotesPage, foreman: () => <ForemanReportsPanel /> };
export const NotesTabsPage = () => <TabbedPage itemId="notes" content={NOTES_TABS} />;
export const TodoTabsPage = () => <TabbedPage itemId="todo" content={TODO_TABS} />;
export const TimeHubPage = () => <TabbedPage itemId="v3-time" content={TIME_TABS} />;
