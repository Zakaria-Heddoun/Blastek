defmodule Blastek.Repo.Migrations.SeedServiceTemplates do
  @moduledoc """
  Starter catalogs for onboarding (E5-T7 / F0.5).

  Seeded by migration rather than by `seeds.exs`, because these are reference
  data every environment needs — an owner onboarding in production must be
  offered the same menu a developer sees. `seeds.exs` builds demo venues and is
  not run in production.

  Names are French, Arabic and English from the start. The wizard's whole point
  is that a salon owner can list their menu in ten minutes on a phone in Arabic;
  a French-only catalog would defeat it, and retrofitting translations in E7
  would mean rewriting rows people had already copied.

  Prices are **hints**, in centimes, at the low end of Casablanca rates. They are
  copied into the venue's own services and edited there — a hint that is too high
  gets accepted unthinkingly, whereas one that is too low gets corrected.
  """
  use Ecto.Migration

  # {catalog, category, fr, ar, en, duration, price hint in MAD}
  @templates [
    # ---- coiffure femme ----
    {"coiffure_femme", "Coiffure", "Coupe femme", "قص شعر نسائي", "Women's cut", 45, 150},
    {"coiffure_femme", "Coiffure", "Brushing", "تصفيف بالسيشوار", "Blow-dry", 30, 100},
    {"coiffure_femme", "Coiffure", "Coupe + brushing", "قص وتصفيف", "Cut and blow-dry", 60, 200},
    {"coiffure_femme", "Couleur", "Coloration racines", "صبغة الجذور", "Root colour", 90, 300},
    {"coiffure_femme", "Couleur", "Balayage", "بالاياج", "Balayage", 150, 600},
    {"coiffure_femme", "Couleur", "Mèches", "خصلات", "Highlights", 120, 450},
    {"coiffure_femme", "Soins", "Soin profond", "علاج عميق", "Deep conditioning", 45, 200},
    {"coiffure_femme", "Soins", "Lissage brésilien", "تمليس برازيلي", "Brazilian blowout", 180,
     900},
    {"coiffure_femme", "Coiffure", "Chignon", "تسريحة", "Updo", 60, 250},

    # ---- coiffure homme ----
    {"coiffure_homme", "Coiffure", "Coupe homme", "قص شعر رجالي", "Men's cut", 30, 80},
    {"coiffure_homme", "Coiffure", "Coupe + barbe", "قص ولحية", "Cut and beard", 45, 120},
    {"coiffure_homme", "Coiffure", "Coupe enfant", "قص للأطفال", "Kids' cut", 20, 50},
    {"coiffure_homme", "Coiffure", "Dégradé", "تدريج", "Fade", 35, 90},
    {"coiffure_homme", "Couleur", "Coloration homme", "صبغة رجالية", "Men's colour", 45, 150},

    # ---- barbier ----
    {"barbier", "Barbier", "Taille de barbe", "تهذيب اللحية", "Beard trim", 20, 60},
    {"barbier", "Barbier", "Rasage traditionnel", "حلاقة تقليدية", "Traditional shave", 30, 80},
    {"barbier", "Barbier", "Serviette chaude", "منشفة ساخنة", "Hot towel shave", 40, 120},
    {"barbier", "Barbier", "Contour", "تحديد", "Line-up", 15, 40},
    {"barbier", "Soins", "Soin du visage homme", "عناية بالوجه للرجال", "Men's facial", 45, 200},

    # ---- onglerie ----
    {"onglerie", "Ongles", "Manucure simple", "مانيكير عادي", "Basic manicure", 30, 80},
    {"onglerie", "Ongles", "Manucure gel", "مانيكير جل", "Gel manicure", 60, 180},
    {"onglerie", "Ongles", "Pédicure", "بديكير", "Pedicure", 45, 120},
    {"onglerie", "Ongles", "Pose capsules", "تركيب أظافر", "Nail extensions", 90, 300},
    {"onglerie", "Ongles", "Dépose", "إزالة", "Removal", 20, 50},
    {"onglerie", "Ongles", "Nail art", "رسم الأظافر", "Nail art", 30, 100},

    # ---- hammam & spa ----
    {"hammam_spa", "Hammam", "Hammam traditionnel", "حمام تقليدي", "Traditional hammam", 60, 150},
    {"hammam_spa", "Hammam", "Gommage corps", "تقشير الجسم", "Body scrub", 45, 120},
    {"hammam_spa", "Hammam", "Enveloppement au ghassoul", "غاسول", "Ghassoul wrap", 60, 200},
    {"hammam_spa", "Massage", "Massage relaxant", "تدليك استرخائي", "Relaxing massage", 60, 300},
    {"hammam_spa", "Massage", "Massage aux pierres chaudes", "تدليك بالحجارة الساخنة",
     "Hot stone massage", 90, 450},
    {"hammam_spa", "Soins", "Soin du visage", "عناية بالوجه", "Facial", 60, 250},
    {"hammam_spa", "Épilation", "Épilation jambes", "إزالة شعر الساقين", "Leg waxing", 45, 150},
    {"hammam_spa", "Épilation", "Épilation sourcils", "تحديد الحواجب", "Eyebrow shaping", 15, 40}
  ]

  def up do
    rows =
      @templates
      |> Enum.with_index()
      |> Enum.map(fn {{catalog, category, fr, ar, en, duration, price}, index} ->
        %{
          catalog: catalog,
          category: category,
          name_i18n: %{"fr" => fr, "ar" => ar, "en" => en},
          duration_min: duration,
          price_hint_cents: price * 100,
          sort: index
        }
      end)

    repo().insert_all("service_templates", rows)
  end

  def down do
    repo().delete_all("service_templates")
  end
end
