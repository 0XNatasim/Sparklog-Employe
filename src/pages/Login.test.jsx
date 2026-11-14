// @vitest-environment jsdom
import React from "react";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup } from "@testing-library/react";

const { signIn, activate } = vi.hoisted(() => ({ signIn: vi.fn(), activate: vi.fn() }));
vi.mock("../supabaseClient", () => ({ supabase: { auth: { signInWithPassword: (...a) => signIn(...a) } } }));
vi.mock("@/supabaseClient", () => ({ supabase: { auth: { signInWithPassword: (...a) => signIn(...a) } } }));
vi.mock("../contexts/AuthContext", () => ({ useAuth: () => ({ user: null, role: null }) }));
vi.mock("react-router-dom", () => ({ useNavigate: () => vi.fn() }));
vi.mock("@/lib/activity-log", () => ({ logActivity: vi.fn() }));
vi.mock("@/components/theme-toggle", () => ({ ThemeToggle: () => null }));
vi.mock("@/components/language-toggle", () => ({ LanguageToggle: () => null }));
vi.mock("@/lib/use-t", () => ({ useT: () => (key) => key }));
vi.mock("@/lib/employee-login", async (orig) => ({ ...(await orig()), activateAccount: (...a) => activate(...a) }));

import Login from "./Login";

const type = (label, value) => fireEvent.change(screen.getByLabelText(label), { target: { value } });
const submit = () => fireEvent.click(screen.getAllByRole("button").find((b) => b.type === "submit"));

afterEach(cleanup);

describe("Login par numéro d'employé", () => {
  beforeEach(() => { signIn.mockReset(); activate.mockReset(); signIn.mockResolvedValue({ error: null }); });

  it("n'a ni inscription, ni courriel, ni mot de passe oublié par courriel", () => {
    render(<Login />);
    expect(screen.queryByLabelText("auth.email")).toBeNull();
    expect(screen.queryByText("auth.noAccount")).toBeNull();
    expect(screen.queryByText("auth.forgotPassword")).toBeNull();
    expect(screen.getByLabelText("login.number")).toBeTruthy();
  });

  it("connecte avec l'adresse factice dérivée du numéro, sans l'afficher", async () => {
    render(<Login />);
    type("login.number", "4821");
    type("auth.password", "mot de passe quelconque");
    submit();
    await waitFor(() => expect(signIn).toHaveBeenCalledWith({ email: "4821@pointage.invalid", password: "mot de passe quelconque" }));
    expect(document.body.textContent).not.toContain("pointage.invalid");
  });

  it("garde le bouton désactivé tant que le numéro est invalide", () => {
    render(<Login />);
    type("login.number", "12");
    type("auth.password", "x");
    expect(screen.getByText("login.numberInvalid")).toBeTruthy();
    expect(screen.getAllByRole("button").find((b) => b.type === "submit").disabled).toBe(true);
  });

  it("ne dit pas lequel des deux est faux quand la connexion échoue", async () => {
    signIn.mockResolvedValue({ error: { message: "Invalid login credentials", status: 400 } });
    render(<Login />);
    type("login.number", "4821");
    type("auth.password", "faux");
    submit();
    expect((await screen.findByRole("alert")).textContent).toBe("login.errors.invalidCredentials");
  });

  it("active : envoie numéro, code et mot de passe, puis se connecte", async () => {
    activate.mockResolvedValue({ ok: true });
    render(<Login />);
    fireEvent.click(screen.getByText("login.activateLink"));
    type("login.number", "4821");
    type("login.code", "abcde-fghjk");
    type("login.newPassword", "une phrase de passe solide");
    type("auth.confirmPassword", "une phrase de passe solide");
    submit();
    await waitFor(() => expect(signIn).toHaveBeenCalled());
    expect(activate.mock.calls[0][1]).toEqual({ number: 4821, code: "abcde-fghjk", password: "une phrase de passe solide" });
    expect(signIn).toHaveBeenCalledWith({ email: "4821@pointage.invalid", password: "une phrase de passe solide" });
  });

  it("n'appelle pas la connexion quand l'activation est refusée, et montre l'erreur précise", async () => {
    activate.mockResolvedValue({ ok: false, error: "code_expired" });
    render(<Login />);
    fireEvent.click(screen.getByText("login.activateLink"));
    type("login.number", "4821");
    type("login.code", "ABCDEFGHJK");
    type("login.newPassword", "une phrase de passe solide");
    type("auth.confirmPassword", "une phrase de passe solide");
    submit();
    expect((await screen.findByRole("alert")).textContent).toBe("login.errors.code_expired");
    expect(signIn).not.toHaveBeenCalled();
  });

  it("bloque l'activation sans envoi pour un mot de passe court, différent, ou contenant le numéro", () => {
    render(<Login />);
    fireEvent.click(screen.getByText("login.activateLink"));
    type("login.number", "4821");
    type("login.code", "ABCDEFGHJK");
    const btn = () => screen.getAllByRole("button").find((b) => b.type === "submit");
    type("login.newPassword", "court"); type("auth.confirmPassword", "court");
    expect(btn().disabled).toBe(true);
    type("login.newPassword", "une phrase de passe solide"); type("auth.confirmPassword", "autre chose complètement");
    expect(screen.getByText("auth.passwordsDoNotMatch")).toBeTruthy();
    expect(btn().disabled).toBe(true);
    type("login.newPassword", "ma phrase 4821 solide"); type("auth.confirmPassword", "ma phrase 4821 solide");
    expect(screen.getByText("login.errors.password_too_guessable")).toBeTruthy();
    expect(btn().disabled).toBe(true);
    expect(activate).not.toHaveBeenCalled();
  });
});
