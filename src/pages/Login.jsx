import React, { useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { Eye, EyeOff } from "lucide-react";
import { supabase } from "../supabaseClient";
import { useAuth } from "../contexts/AuthContext";
import { isManagerRole } from "@/lib/roles";
import { logActivity } from "@/lib/activity-log";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { ThemeToggle } from "@/components/theme-toggle";
import { LanguageToggle } from "@/components/language-toggle";
import { useT } from "@/lib/use-t";
import { withTimeout } from "@/lib/utils";
import {
  activateAccount, activationErrorKey, isValidCodeFormat, loginEmail, parseEmployeeNumber, passwordProblem,
} from "@/lib/employee-login";

// Connexion par numéro d'employé. Deux écrans :
//  - « login » : numéro + mot de passe (l'adresse de connexion factice `<numéro>@pointage.invalid` n'est jamais affichée) ;
//  - « activate » : numéro + code d'activation remis par la gestion + mot de passe choisi, puis connexion directe.
// Aucune inscription libre, aucun courriel, aucun « mot de passe oublié » par courriel : un nouveau code vient de la gestion.
const SERVICE = { url: import.meta.env.VITE_SUPABASE_URL, anonKey: import.meta.env.VITE_SUPABASE_ANON_KEY };

// Erreur de connexion → texte. Un refus d'identifiants ne dit jamais lequel des deux est faux.
function signInErrorKey(err) {
  const status = err?.status ?? err?.statusCode ?? 0;
  const raw = typeof err?.message === "string" ? err.message.trim() : "";
  if (/invalid login credentials/i.test(raw)) return "login.errors.invalidCredentials";
  const transient = status >= 500 || status === 429 || status === 408 || raw === "" || raw === "{}" ||
    /timeout|timed out|failed to fetch|load failed|networkerror|fetch/i.test(raw);
  return transient ? "login.errors.network" : "login.errors.generic";
}

export default function Login() {
  const navigate = useNavigate();
  const { user, role } = useAuth();
  const t = useT();

  const [mode, setMode] = useState("login");
  const [number, setNumber] = useState("");
  const [code, setCode] = useState("");
  const [password, setPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [loading, setLoading] = useState(false);
  const [errorKey, setErrorKey] = useState("");

  const isActivate = mode === "activate";
  const parsedNumber = parseEmployeeNumber(number);
  const clearError = () => { if (errorKey) setErrorKey(""); };

  React.useEffect(() => {
    if (user) navigate(isManagerRole(role) ? "/manager" : "/", { replace: true });
  }, [user, role, navigate]);

  const pwProblem = isActivate ? passwordProblem(password, parsedNumber, code) : null;
  const mismatch = isActivate && confirmPassword !== "" && confirmPassword !== password;

  const canSubmit = useMemo(() => {
    if (parsedNumber == null || !password) return false;
    if (!isActivate) return true;
    return isValidCodeFormat(code) && !passwordProblem(password, parsedNumber, code) && password.length > 0 && confirmPassword === password;
  }, [parsedNumber, password, isActivate, code, confirmPassword]);

  async function signIn() {
    const { error } = await withTimeout(supabase.auth.signInWithPassword({ email: loginEmail(parsedNumber), password }), 12000);
    if (error) throw error;
    logActivity("login");
  }

  async function handleSubmit(e) {
    e.preventDefault();
    setErrorKey("");
    if (!canSubmit || loading) return;
    setLoading(true);
    try {
      if (isActivate) {
        const result = await activateAccount(SERVICE, { number: parsedNumber, code, password });
        if (!result.ok) { setErrorKey(activationErrorKey(result.error)); return; }
      }
      await signIn();
    } catch (err) {
      setErrorKey(signInErrorKey(err));
    } finally {
      setLoading(false);
    }
  }

  function switchMode(next) {
    setErrorKey("");
    setPassword("");
    setConfirmPassword("");
    setCode("");
    setShowPassword(false);
    setMode(next);
  }

  return (
    <div className="min-h-screen grid place-items-center bg-background text-foreground p-4">
      <div className="absolute right-4 top-4 flex items-center gap-1">
        <ThemeToggle />
        <LanguageToggle />
      </div>
      <Card className="w-full max-w-md dark:bg-background">
        <div className="flex justify-center px-6 pt-6">
          <img src="/header-light.webp" alt="Messier Connexion" className="w-64 max-w-full rounded dark:hidden" />
          <img src="/header-dark.webp" alt="Messier Connexion" className="hidden w-64 max-w-full dark:block" />
        </div>
        <CardHeader>
          <CardTitle className="text-2xl">{t("auth.title")}</CardTitle>
          <CardDescription>{isActivate ? t("login.descActivate") : t("login.descLogin")}</CardDescription>
        </CardHeader>
        <CardContent>
          <form onSubmit={handleSubmit} className="grid gap-3">
            <div className="grid gap-1.5">
              <Label htmlFor="employeeNumber">{t("login.number")}</Label>
              <Input
                id="employeeNumber"
                value={number}
                onChange={(e) => { setNumber(e.target.value); clearError(); }}
                placeholder={t("login.numberPlaceholder")}
                inputMode="numeric"
                autoComplete="username"
                autoFocus
              />
              {number.trim() !== "" && parsedNumber == null && (
                <span className="text-xs text-destructive">{t("login.numberInvalid")}</span>
              )}
            </div>

            {isActivate && (
              <div className="grid gap-1.5">
                <Label htmlFor="activationCode">{t("login.code")}</Label>
                <Input
                  id="activationCode"
                  value={code}
                  onChange={(e) => { setCode(e.target.value); clearError(); }}
                  placeholder={t("login.codePlaceholder")}
                  autoComplete="one-time-code"
                  autoCapitalize="characters"
                  spellCheck={false}
                />
                {code.trim() !== "" && !isValidCodeFormat(code) && (
                  <span className="text-xs text-destructive">{t("login.codeInvalid")}</span>
                )}
              </div>
            )}

            <div className="grid gap-1.5">
              <Label htmlFor="password">{isActivate ? t("login.newPassword") : t("auth.password")}</Label>
              <div className="relative">
                <Input
                  id="password"
                  value={password}
                  onChange={(e) => { setPassword(e.target.value); clearError(); }}
                  type={showPassword ? "text" : "password"}
                  autoComplete={isActivate ? "new-password" : "current-password"}
                  className="pr-10"
                />
                <button
                  type="button"
                  className="absolute right-2 top-1/2 -translate-y-1/2 text-muted-foreground"
                  onClick={() => setShowPassword((v) => !v)}
                  aria-label={t("auth.togglePasswordVisibility")}
                >
                  {showPassword ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
                </button>
              </div>
              {isActivate && <span className="text-xs text-muted-foreground">{t("login.passwordRule")}</span>}
              {pwProblem && <span className="text-xs text-destructive">{t(`login.errors.${pwProblem}`)}</span>}
            </div>

            {isActivate && (
              <div className="grid gap-1.5">
                <Label htmlFor="confirmPassword">{t("auth.confirmPassword")}</Label>
                <Input
                  id="confirmPassword"
                  value={confirmPassword}
                  onChange={(e) => { setConfirmPassword(e.target.value); clearError(); }}
                  type={showPassword ? "text" : "password"}
                  autoComplete="new-password"
                />
                {mismatch && <span className="text-xs text-destructive">{t("auth.passwordsDoNotMatch")}</span>}
              </div>
            )}

            {errorKey && (
              <div role="alert" className="rounded-md border border-destructive/30 bg-destructive/10 px-3 py-2 text-sm text-destructive">
                {t(errorKey)}
              </div>
            )}

            <Button disabled={!canSubmit || loading} type="submit" className="mt-1">
              {loading ? t("common.pleaseWait") : isActivate ? t("login.activateButton") : t("auth.loginButton")}
            </Button>

            {!isActivate && <p className="text-center text-xs text-muted-foreground">{t("login.forgotHelp")}</p>}

            <Button type="button" variant="link" onClick={() => switchMode(isActivate ? "login" : "activate")}>
              {isActivate ? t("login.backToLogin") : t("login.activateLink")}
            </Button>
          </form>
        </CardContent>
      </Card>
    </div>
  );
}
