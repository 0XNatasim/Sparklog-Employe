// Annonces reçues par l'employé (migration 0011) : table `announcement_recipients` jointe à `announcements`.
// Les écrans gardent la forme { broadcast_id, acknowledged_at, manager_broadcasts: { body, created_at, attachments, edited_at } } ;
// cette fonction fait la traduction à un seul endroit. Une annonce retirée par le côté 2 (`withdrawn_at`) n'est jamais lue.
export const ANNOUNCEMENT_COLUMNS = "announcement_id, acknowledged_at, announcements(body, created_at, attachments, edited_at)";

export const toBroadcastItem = (row) => ({
  broadcast_id: row.announcement_id,
  acknowledged_at: row.acknowledged_at,
  manager_broadcasts: row.announcements || null,
});

export function fetchMyAnnouncements(client, userId, { unreadOnly = false } = {}) {
  let query = client.from("announcement_recipients").select(ANNOUNCEMENT_COLUMNS).eq("employee_id", userId).is("withdrawn_at", null);
  if (unreadOnly) query = query.is("acknowledged_at", null);
  return query.then(({ data }) => (data || []).map(toBroadcastItem));
}

// L'employé n'accuse réception qu'une fois (colonne `acknowledged_at`, seule modifiable par lui).
export function acknowledgeAnnouncement(client, userId, announcementId, at = new Date().toISOString()) {
  return client.from("announcement_recipients").update({ acknowledged_at: at }).eq("announcement_id", announcementId).eq("employee_id", userId);
}
