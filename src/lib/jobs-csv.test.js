import { describe, expect, it } from "vitest";
import { JOBS_CSV_COLUMNS, csvCell, fetchJobsForExport, jobsCsvFileName, jobsToCsv } from "./jobs-csv";

const row = (over = {}) => ({ employee_number: 4821, job_date: "2026-11-10", depart: "07:00:00", arrivee: "08:00:00", fin: "15:00:00", km_aller: 12.5, km_retour: 0, km_total: 12.5,
  return_time_minutes: 0, ot: "OT 100", status: "approved", job_id: "00000000-0000-4000-8000-000000000001", updated_at: "2026-11-10T21:00:00+00:00", ...over });

describe("export CSV des fiches", () => {
  it("écrit l'en-tête, une ligne par fiche, le BOM et des fins de ligne CRLF", () => {
    const csv = jobsToCsv([row(), row({ job_id: "00000000-0000-4000-8000-000000000002", km_aller: null })]);
    expect(csv.startsWith("﻿" + JOBS_CSV_COLUMNS.join(";") + "\r\n")).toBe(true);
    const lines = csv.trim().split("\r\n");
    expect(lines).toHaveLength(3);
    expect(lines[1]).toBe("4821;2026-11-10;07:00:00;08:00:00;15:00:00;12.5;0;12.5;0;OT 100;approved;00000000-0000-4000-8000-000000000001;2026-11-10T21:00:00+00:00");
    expect(lines[2].split(";")[5]).toBe("");
  });

  it("n'écrit que des numéros : aucune colonne de nom, de courriel ni de téléphone", () => {
    expect(JOBS_CSV_COLUMNS.join(" ")).not.toMatch(/name|nom|mail|phone|tel/i);
    expect(JOBS_CSV_COLUMNS[0]).toBe("employee_number");
  });

  it("protège contre les formules et met entre guillemets ce qui contient ; \" ou un retour de ligne", () => {
    expect(csvCell("=SOMME(A1)")).toBe("'=SOMME(A1)");
    expect(csvCell("+1")).toBe("'+1");
    expect(csvCell("-FORMATION")).toBe("'-FORMATION");
    expect(csvCell("@cmd")).toBe("'@cmd");
    expect(csvCell("\t=x")).toBe("'\t=x");
    expect(csvCell("a;b")).toBe('"a;b"');
    expect(csvCell('il dit "oui"')).toBe('"il dit ""oui"""');
    expect(csvCell("deux\nlignes")).toBe('"deux\nlignes"');
    expect(csvCell(-5)).toBe("-5");          // un nombre négatif n'est pas une formule
    expect(csvCell(null)).toBe("");
    expect(csvCell(undefined)).toBe("");
  });

  it("nom de fichier par période", () => expect(jobsCsvFileName("2026-11-01", "2026-11-14")).toBe("fiches_2026-11-01_2026-11-14.csv"));

  it("lit les fiches par la fonction du serveur et laisse remonter ses erreurs", async () => {
    const calls = [];
    const client = { rpc: async (name, args) => { calls.push([name, args]); return { data: [row()], error: null }; } };
    expect((await fetchJobsForExport(client, { from: "2026-11-01", to: "2026-11-14", statuses: ["approved", "submitted"] })).rows).toHaveLength(1);
    expect(calls[0]).toEqual(["export_jobs_for_import", { p_from: "2026-11-01", p_to: "2026-11-14", p_statuses: ["approved", "submitted"] }]);
    await expect(fetchJobsForExport({ rpc: async () => ({ data: null, error: { code: "42501", message: "manager_role_required" } }) }, { from: "a", to: "b" })).rejects.toMatchObject({ code: "42501" });
  });
});
