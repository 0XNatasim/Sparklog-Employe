// @vitest-environment jsdom
// Profil côté 1 : le numéro d'employé et rien de nominatif ; en « Vue en tant que », le numéro de l'employé vu.
import React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import { dictionaries } from "@/lib/i18n";
import { createFakeSupabase } from "@/test/fake-supabase";

const fr = (key) => dictionaries.fr[key];
const state = vi.hoisted(() => ({ fake: null, auth: null, view: null }));
vi.mock("@/supabaseClient", () => ({ get supabase() { return state.fake.client; } }));
vi.mock("@/contexts/AuthContext", () => ({ useAuth: () => state.auth }));
vi.mock("@/contexts/ViewModeContext", () => ({ useViewMode: () => state.view }));
vi.mock("@/components/AppShell", () => ({ default: ({ children }) => <div>{children}</div> }));
vi.mock("@/components/PushNotificationsToggle", () => ({ default: () => <div>push-toggle</div> }));
vi.mock("@/components/TwoFactor", () => ({ TwoFactorSettings: () => <div>2fa</div> }));
vi.mock("@/components/CcqCalendarCard", () => ({ CcqCalendarCard: () => null }));
vi.mock("@/lib/use-ccq-calendar", () => ({ useCcqCalendar: () => ({ blocks: [], today: "2026-11-14", loaded: true }) }));

const { default: Profile } = await import("./Profile");
afterEach(cleanup);

function setup({ viewing }) {
  state.auth = { user: { id: viewing ? "mgr" : "emp" }, role: viewing ? "manager" : "employee", employeeNumber: 4821 };
  state.view = viewing ? { isViewMode: true, viewedEmployee: { id: "emp-9" } } : { isViewMode: false, viewedEmployee: null };
  state.fake = createFakeSupabase({ tables: { profiles: [{ id: "emp-9", employee_number: 7302, full_name: "Ne pas montrer", email: "x@y.z" }] } });
  return render(<Profile />);
}

describe("Profile (côté 1)", () => {
  it("montre le numéro de l'employé connecté, sans champ nominatif", () => {
    setup({ viewing: false });
    expect(screen.getByText(fr("login.number"))).toBeTruthy();
    expect(screen.getByText("4821")).toBeTruthy();
    expect(screen.queryByText(fr("auth.fullName"))).toBeNull();
    expect(screen.queryByText(fr("auth.email"))).toBeNull();
    expect(screen.getByText("push-toggle")).toBeTruthy();
  });

  it("en vue employé : le numéro de l'employé vu, sans notifications ni double authentification", async () => {
    setup({ viewing: true });
    await waitFor(() => expect(screen.getByText("7302")).toBeTruthy());
    expect(screen.queryByText("4821")).toBeNull();
    expect(screen.queryByText("push-toggle")).toBeNull();
    expect(screen.queryByText("2fa")).toBeNull();
    expect(document.body.textContent).not.toMatch(/Ne pas montrer|x@y\.z/);
  });
});
