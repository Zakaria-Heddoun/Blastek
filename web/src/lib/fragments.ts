// Selection sets shared by the marketplace and dashboard bootstrap queries, so
// a schema change is a one-file edit.
export const F = {
  settings: `settings { businessName businessTagline businessAddress businessPhone }`,
  categories: `categories { id name sort }`,
  services: `services { id categoryId name description durationMin priceCents active staffIds }`,
  staff: `staff { id name role color active hours { weekday working startMin endMin } serviceIds }`,
  // Every rendered size, so a caller can pick per slot rather than downloading
  // a hero-sized image for a thumbnail.
  photos: `photos { id alt kind sort status width height urls { original thumb card hero } }`,
};
