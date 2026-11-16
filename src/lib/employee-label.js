// Libellé d'un employé côté 1 : le numéro, jamais un nom (invariant I1 de PLAN.md). Texte vide si le numéro est inconnu.
export function employeeLabel(profile) {
  const n = profile?.employee_number;
  return Number.isInteger(n) ? `#${String(n).padStart(4, "0")}` : "";
}
