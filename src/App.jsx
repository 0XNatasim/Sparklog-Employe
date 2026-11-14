// src/App.jsx
import React, { Suspense, lazy } from "react";
import { HashRouter, Routes, Route, Navigate, useLocation } from "react-router-dom";
import ProtectedRoute from "./components/ProtectedRoute";
import { useAuth } from "./contexts/AuthContext";
import { OLD_PATHS } from "./lib/manager-nav";

import Login from "./pages/Login";
import EmployeeForm from "./pages/EmployeeForm";
import { PageLoading } from "@/components/LazyLoading";
import { ErrorBoundary } from "@/components/ErrorBoundary";

// The time-entry form (employees' landing page) and login stay in the main bundle;
// everything else loads on first visit. Manager code is never sent to employees.
const History = lazy(() => import("./pages/History"));
const Week = lazy(() => import("./pages/Week"));
const Profile = lazy(() => import("./pages/Profile"));
const ManagerLayout = lazy(() => import("./components/manager/ManagerLayout"));
const managerPage = (name) => lazy(() => import("./pages/manager/ManagerPages").then((m) => ({ default: m[name] })));
const AuditPage = managerPage("AuditPage");
const EmergencyPage = managerPage("EmergencyPage");
const LivePage = managerPage("LivePage");
const TodoTabsPage = managerPage("TodoTabsPage");
const NotesTabsPage = managerPage("NotesTabsPage");
const TimeHubPage = managerPage("TimeHubPage");
const ManagerIndex = managerPage("ManagerIndex");
const InventoryPage = managerPage("InventoryPage");
const InventoryMinimumsPage = managerPage("InventoryMinimumsPage");
const OldPathRedirect = managerPage("OldPathRedirect");
import { ViewModeProvider } from "@/contexts/ViewModeProvider";
import { isManagerRole } from "@/lib/roles";
import InstallPrompt from "@/components/InstallPrompt";

// Landing route: managers/owners start on the Manager dashboard; employees — including
// administration (office) staff, who are non-manager employees — start on the form.
function RoleLanding() {
  const { role } = useAuth();
  // Role loads just after `loading` clears; wait for it so a manager is not
  // sent to /form before their role resolves.
  if (!role) return null;
  return <Navigate to={isManagerRole(role) ? "/manager" : "/form"} replace />;
}

// A crash on one page shows a recoverable error instead of a blank app; changing
// page clears it.
function RouteErrorBoundary({ children }) {
  const { pathname } = useLocation();
  return <ErrorBoundary resetKey={pathname}>{children}</ErrorBoundary>;
}

export default function App() {
  React.useEffect(() => {
    // If the user landed on a non-root path (e.g. /form from a stale bookmark),
    // collapse it to "/" so HashRouter takes over cleanly.
    const { pathname, hash, search } = window.location;
    if (pathname !== "/" && !hash) {
      window.history.replaceState(null, "", `/${search}${hash}`);
    }
  }, []);

  return (
    <HashRouter>
      <ViewModeProvider>
      <InstallPrompt />
      <RouteErrorBoundary>
      <Suspense fallback={<PageLoading />}>
      <Routes>
        {/* Public */}
        <Route path="/login" element={<Login />} />

        {/* Landing: managers → Manager dashboard, employees → form */}
        <Route
          path="/"
          element={
            <ProtectedRoute>
              <RoleLanding />
            </ProtectedRoute>
          }
        />
        <Route
          path="/form"
          element={
            <ProtectedRoute>
              <EmployeeForm />
            </ProtectedRoute>
          }
        />

        {/* History */}
        <Route
          path="/history"
          element={
            <ProtectedRoute>
              <History />
            </ProtectedRoute>
          }
        />

        {/* Week summary (employee + manager can access; manager will get employee dropdown) */}
        <Route
          path="/week"
          element={
            <ProtectedRoute>
              <Week />
            </ProtectedRoute>
          }
        />

        <Route
          path="/profile"
          element={
            <ProtectedRoute>
              <Profile />
            </ProtectedRoute>
          }
        />

        {/* Gestion: sidebar layout; every page has its own URL (#/manager/…). The layout
            itself re-checks each page against canAccessSection. */}
        <Route
          path="/manager"
          element={
            <ProtectedRoute requireRole="manager">
              <ManagerLayout />
            </ProtectedRoute>
          }
        >
          <Route index element={<ManagerIndex />} />
          <Route path="live" element={<LivePage />} />
          <Route path="todo" element={<TodoTabsPage />} />
          <Route path="inventory" element={<InventoryPage />} />
          <Route path="inventory/minimums" element={<InventoryMinimumsPage />} />
          {/* Pages with tabs (paths kept from Gestion V3, so links stay valid) */}
          <Route path="v3/time" element={<TimeHubPage />} />
          <Route path="advanced" element={<Navigate to="audit" replace />} />
          <Route path="advanced/audit" element={<AuditPage />} />
          <Route path="notes" element={<NotesTabsPage />} />
          <Route path="advanced/emergency" element={<EmergencyPage />} />
          {/* Old paths (the V2 menu, removed in V2.4.186) → the page and tab that hold them now */}
          {Object.keys(OLD_PATHS).map((path) => <Route key={path} path={path} element={<OldPathRedirect />} />)}
          <Route path="*" element={<Navigate to="/manager" replace />} />
        </Route>

        {/* Fallback */}
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
      </Suspense>
      </RouteErrorBoundary>
      </ViewModeProvider>
    </HashRouter>
  );
}
