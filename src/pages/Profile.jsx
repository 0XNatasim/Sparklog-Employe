import React, { useEffect, useState } from "react";
import { ChevronDown, Hash, ShieldCheck, UserRound } from "lucide-react";
import { supabase } from "@/supabaseClient";
import { useAuth } from "@/contexts/AuthContext";
import AppShell from "@/components/AppShell";
import { Card } from "@/components/ui/card";
import { useT } from "@/lib/use-t";
import { useViewMode } from "@/contexts/ViewModeContext";
import PushNotificationsToggle from "@/components/PushNotificationsToggle";
import { TwoFactorSettings } from "@/components/TwoFactor";
import { requiresMfa } from "@/lib/mfa";
import { CcqCalendarCard } from "@/components/CcqCalendarCard";
import { useCcqCalendar } from "@/lib/use-ccq-calendar";

// Profil côté 1 : le numéro d'employé, et rien de nominatif (pas de nom, courriel, téléphone, région, syndicat ni carte CCQ : ils n'existent pas ici).
// En « Vue en tant que », le gestionnaire lit le numéro de l'employé vu (lecture permise par la politique des profils).
export default function Profile() {
  const t = useT();
  const { user, role, employeeNumber } = useAuth();
  const { isViewMode, viewedEmployee } = useViewMode();
  const [viewed, setViewed] = useState({ id: null, number: null });
  const [error, setError] = useState("");
  const calendar = useCcqCalendar();

  useEffect(() => {
    if (!isViewMode || !viewedEmployee?.id) return undefined;
    let alive = true;
    supabase.from("profiles").select("employee_number").eq("id", viewedEmployee.id).single().then(({ data, error: readError }) => {
      if (!alive) return;
      if (readError) setError(readError.message);
      else setViewed({ id: viewedEmployee.id, number: data?.employee_number ?? null });
    });
    return () => { alive = false; };
  }, [isViewMode, viewedEmployee?.id]);

  // Le numéro lu n'est montré que s'il est celui de l'employé vu (pas celui du précédent pendant le chargement).
  const number = isViewMode ? (viewed.id === viewedEmployee?.id ? viewed.number : null) : employeeNumber;

  return (
    <AppShell>
      <div className="space-y-4">
        <div>
          <h1 className="text-2xl font-bold">{t("profile.title")}</h1>
          <p className="text-sm text-muted-foreground">{t("profile.description")}</p>
        </div>
        {error && <div role="alert" className="rounded-md bg-destructive/10 p-3 text-sm text-destructive">{error}</div>}

        <CollapsibleCard icon={UserRound} title={t("profile.information")} defaultOpen>
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            <Info label={t("login.number")} value={number == null ? "" : String(number)} icon={Hash} />
          </div>
          {!isViewMode && user && <PushNotificationsToggle />}
        </CollapsibleCard>

        {!isViewMode && requiresMfa(role) && (
          <CollapsibleCard icon={ShieldCheck} title={t("mfa.settingsTitle")} description={t("mfa.settingsDescription")}>
            <TwoFactorSettings bare />
          </CollapsibleCard>
        )}

        <CcqCalendarCard blocks={calendar.blocks} today={calendar.today} loaded={calendar.loaded} />
      </div>
    </AppShell>
  );
}

function CollapsibleCard({ icon: Icon, title, description, defaultOpen = false, children }) {
  return (
    <Card>
      <details className="group" open={defaultOpen}>
        <summary className="flex cursor-pointer list-none items-center justify-between gap-2 p-4 select-none [&::-webkit-details-marker]:hidden">
          <span className="flex flex-col">
            <span className="flex items-center gap-2 font-semibold">{Icon && <Icon className="h-5 w-5 text-primary" />}{title}</span>
            {description && <span className="mt-1 text-sm text-muted-foreground">{description}</span>}
          </span>
          <ChevronDown className="h-4 w-4 shrink-0 text-muted-foreground transition-transform group-open:rotate-180" />
        </summary>
        <div className="border-t p-4">{children}</div>
      </details>
    </Card>
  );
}

function Info({ label, value, icon: Icon }) {
  return (
    <div className="rounded-lg bg-muted/50 p-4">
      <div className="mb-2 flex items-center gap-2 text-xs font-semibold uppercase tracking-wide text-muted-foreground"><Icon className="h-4 w-4" />{label}</div>
      <span className="break-words font-medium">{value || "—"}</span>
    </div>
  );
}
