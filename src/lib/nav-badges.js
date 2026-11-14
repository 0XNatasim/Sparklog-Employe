// Somme des pastilles des entrées d'un groupe du menu, affichée sur l'en-tête du groupe tant qu'il est fermé.
export function groupBadgeTotal(items, badges) {
  return (items || []).reduce((sum, item) => sum + (Number(badges?.[item.id]) || 0), 0);
}
