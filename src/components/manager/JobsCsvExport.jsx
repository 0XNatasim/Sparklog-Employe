import React, { useState } from "react";
import { FileDown } from "lucide-react";
import dayjs from "dayjs";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { EXPORT_STATUSES, fetchJobsForExport, jobsCsvFileName, jobsToCsv } from "@/lib/jobs-csv";
import { friendlyErrorMessage } from "@/lib/error-messages";
import { useT } from "@/lib/use-t";
import { supabase } from "@/supabaseClient";

// Plan de secours de la synchronisation avec la gestion (PLAN.md 4.0) : les fiches d'une période en CSV, par numéro d'employé, à importer dans la gestion
// puis à SUPPRIMER. Gestionnaire avec double authentification seulement (la base le vérifie) ; chaque export est écrit au journal (nombre de fiches).
export default function JobsCsvExport() {
  const t = useT();
  const [open, setOpen] = useState(false);
  const [from, setFrom] = useState(() => dayjs().subtract(31, "day").format("YYYY-MM-DD"));
  const [to, setTo] = useState(() => dayjs().format("YYYY-MM-DD"));
  const [statuses, setStatuses] = useState(["approved"]);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  const toggle = (status) => setStatuses((current) => (current.includes(status) ? current.filter((s) => s !== status) : [...current, status]));
  const valid = from && to && from <= to && statuses.length > 0;

  async function download() {
    setBusy(true); setError(""); setMessage("");
    try {
      const { rows } = await fetchJobsForExport(supabase, { from, to, statuses });
      if (!rows.length) { setMessage(t("jobsCsv.empty")); return; }
      const url = URL.createObjectURL(new Blob([jobsToCsv(rows)], { type: "text/csv;charset=utf-8" }));
      const link = document.createElement("a");
      link.href = url; link.download = jobsCsvFileName(from, to);
      document.body.appendChild(link); link.click(); link.remove();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
      setMessage(t("jobsCsv.done", { count: rows.length }));
    } catch (e) {
      setError(friendlyErrorMessage(e, t, "jobsCsv.error"));
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <Button type="button" variant="outline" size="sm" onClick={() => setOpen(true)}><FileDown className="mr-1.5 h-4 w-4" />{t("jobsCsv.open")}</Button>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t("jobsCsv.title")}</DialogTitle>
            <DialogDescription>{t("jobsCsv.description")}</DialogDescription>
          </DialogHeader>
          <div className="grid gap-3">
            <div className="grid grid-cols-2 gap-2">
              <label className="grid gap-1 text-sm font-medium">{t("jobsCsv.from")}<Input type="date" value={from} max={to} onChange={(e) => setFrom(e.target.value)} /></label>
              <label className="grid gap-1 text-sm font-medium">{t("jobsCsv.to")}<Input type="date" value={to} min={from} onChange={(e) => setTo(e.target.value)} /></label>
            </div>
            <fieldset className="flex flex-wrap gap-3 text-sm">
              {EXPORT_STATUSES.map((status) => (
                <label key={status} className="flex items-center gap-1.5"><input type="checkbox" className="h-4 w-4" checked={statuses.includes(status)} onChange={() => toggle(status)} />{t(`status.${status}`)}</label>
              ))}
            </fieldset>
            <p className="text-xs text-muted-foreground">{t("jobsCsv.deleteReminder")}</p>
            {error && <div role="alert" className="rounded-md border border-destructive/30 bg-destructive/10 px-3 py-2 text-sm text-destructive">{error}</div>}
            {message && <div role="status" className="rounded-md border border-success/30 bg-success/10 px-3 py-2 text-sm text-success">{message}</div>}
            <Button type="button" disabled={!valid || busy} onClick={download}>{busy ? t("common.working") : t("jobsCsv.download")}</Button>
          </div>
        </DialogContent>
      </Dialog>
    </>
  );
}
