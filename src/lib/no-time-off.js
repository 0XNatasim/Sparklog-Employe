// Le temps libre (absences, congés) appartient au côté 2 (décision du 2026-11-14) : le côté 1 ne le lit plus.
// Les calculs qui acceptent des lignes de temps libre (live-crew.js, missing-days.js…) reçoivent donc une liste vide.
export const noTimeOff = () => Promise.resolve({ data: [], error: null });
