// Export CSV des fiches pour l'import du côté 2 (PLAN.md 4.0 : plan de secours / démarrage de la synchronisation). Par NUMÉRO d'employé, jamais un nom.
// Même colonnes que `csv-import.js` du côté 2. Protégé contre les formules : une cellule de texte qui commence par = + - @ (ou une tabulation / un retour de chariot)
// reçoit une apostrophe devant, que l'import retire. Le fichier doit être supprimé après l'import.
export const JOBS_CSV_COLUMNS = ["employee_number", "job_date", "depart", "arrivee", "fin", "km_aller", "km_retour", "km_total", "return_time_minutes", "ot", "status", "job_id", "updated_at"];
export const EXPORT_STATUSES = Object.freeze(["approved", "submitted", "saved", "updated"]);

export function csvCell(value) {
  if (value === null || value === undefined) return "";
  let text = String(value);
  if (/^[=+\-@\t\r]/.test(text) && typeof value === "string") text = `'${text}`;
  return /[;"\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

// Séparateur « ; » (Excel en français), BOM UTF-8 pour l'ouverture directe, lignes terminées par CRLF.
export function jobsToCsv(rows) {
  const lines = [JOBS_CSV_COLUMNS.join(";"), ...(rows || []).map((row) => JOBS_CSV_COLUMNS.map((column) => csvCell(row[column])).join(";"))];
  return `\uFEFF${lines.join("\r\n")}\r\n`;
}

export const jobsCsvFileName = (from, to) => `fiches_${from}_${to}.csv`;

// Les fiches de la période (RPC `export_jobs_for_import`, gestionnaire avec double authentification). Renvoie { rows } ou lève l'erreur de la base.
export async function fetchJobsForExport(client, { from, to, statuses = ["approved"] }) {
  const { data, error } = await client.rpc("export_jobs_for_import", { p_from: from, p_to: to, p_statuses: statuses });
  if (error) throw error;
  return { rows: data || [] };
}
