// Selection sets shared by the marketplace and dashboard bootstrap queries, so
// a schema change is a one-file edit.
export const F = {
  settings: `settings { businessName businessTagline businessAddress businessPhone }`,
  categories: `categories { id name sort }`,
  services: `services { id categoryId name description durationMin priceCents active staffIds }`,
  // Per-locale values, for the catalog editor only. Deliberately *not* in the
  // fragments above: those are shared with the public venue page, which renders
  // `name` already resolved for the reader and would otherwise download every
  // other language it will never show.
  translations: `translations`,
  staff: `staff { id name role color active hours { weekday working startMin endMin } serviceIds }`,
  // Every rendered size, so a caller can pick per slot rather than downloading
  // a hero-sized image for a thumbnail.
  photos: `photos { id alt kind sort status width height urls { original thumb card hero } }`,
};
