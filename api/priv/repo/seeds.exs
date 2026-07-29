# Demo data: two venues, so multi-tenancy is exercised from the first run.
#
#   1. Le Salon Anfa (Casablanca) — full-service salon, 4 staff, 15 services,
#      18 clients and ~5 weeks of appointment + sales history.
#   2. Barber Corner (Rabat)      — a small barbershop with its own team,
#      catalog and clients. Nothing is shared between the two.
#
# Deterministic (:rand is seeded) so reseeding is stable.

import Ecto.Query

alias Blastek.Repo
alias Blastek.Accounts
alias Blastek.Venues

alias Blastek.Salon.{
  Category,
  Service,
  Staff,
  StaffHour,
  Client,
  Appointment,
  Sale,
  SaleItem,
  Review
}

if Repo.aggregate(Venues.Venue, :count) > 0 do
  IO.puts("Already seeded — run `mix ecto.reset` to reseed.")
else
  :rand.seed(:exsss, {530, 2026, 7})
  pick = fn list -> Enum.at(list, :rand.uniform(length(list)) - 1) end
  ri = fn lo, hi -> lo + :rand.uniform(hi - lo + 1) - 1 end
  now = NaiveDateTime.local_now() |> NaiveDateTime.truncate(:second)

  # --------------------------------------------------------------------------
  # Builds one complete venue: catalog, team, clients, history and reviews.
  # --------------------------------------------------------------------------
  seed_venue = fn config ->
    {:ok, venue} =
      Venues.create_venue(%{
        name: config.name,
        slug: config.slug,
        tagline: config.tagline,
        address: config.address,
        city: config.city,
        phone: config.phone,
        status: "active"
      })

    vid = venue.id

    cats =
      for {name, sort} <- config.categories,
          into: %{},
          do: {name, Repo.insert!(%Category{name: name, sort: sort, venue_id: vid}).id}

    services =
      for {key, cat, name, desc, dur, price} <- config.services, into: %{} do
        {key,
         Repo.insert!(%Service{
           category_id: cats[cat],
           name: name,
           description: desc,
           duration_min: dur,
           price_cents: price * 100,
           venue_id: vid
         }).id}
      end

    staff_ids =
      for {key, name, role, color} <- config.staff, into: %{} do
        {key, Repo.insert!(%Staff{name: name, role: role, color: color, venue_id: vid}).id}
      end

    skills =
      Map.new(config.skills, fn {staff_key, service_keys} ->
        {staff_ids[staff_key], Enum.map(service_keys, &services[&1])}
      end)

    skill_rows =
      for {staff_id, service_ids} <- skills, sid <- service_ids do
        %{staff_id: staff_id, service_id: sid}
      end

    Repo.insert_all("staff_services", skill_rows)

    hours =
      for {key, staff_id} <- staff_ids, wd <- 0..6 do
        %{
          staff_id: staff_id,
          weekday: wd,
          working: config.working.(key, wd),
          start_min: config.open_min,
          end_min: if(wd == 6, do: config.close_min - 60, else: config.close_min)
        }
      end

    Repo.insert_all(StaffHour, hours)

    client_ids =
      for {first, last, allergy} <- config.clients do
        email =
          String.downcase(
            "#{String.replace(first, " ", "")}.#{String.replace(last, " ", "")}@example.com"
          )

        phone = "+212 6 #{ri.(10, 99)} #{ri.(10, 99)} #{ri.(10, 99)} #{ri.(10, 99)}"
        created = NaiveDateTime.add(now, -ri.(5, 90) * 86_400, :second)

        Repo.insert!(%Client{
          first_name: first,
          last_name: last,
          email: email,
          phone: phone,
          allergies: allergy,
          venue_id: vid,
          inserted_at: created,
          updated_at: created
        }).id
      end

    ## ---- appointments + sales over the configured window ----
    services_by_id = Repo.all(Service) |> Map.new(&{&1.id, &1})
    hours_by = Map.new(hours, fn h -> {{h.staff_id, h.weekday}, h} end)
    today = NaiveDateTime.to_date(now)
    now_min = now.hour * 60 + now.minute

    for off <- config.day_range, staff_id <- Map.values(staff_ids) do
      date = Date.add(today, off)
      weekday = Date.day_of_week(date, :sunday) - 1
      h = hours_by[{staff_id, weekday}]

      if h && h.working do
        target = if off <= 0, do: ri.(3, 5), else: ri.(1, 4)

        Enum.reduce(1..target, h.start_min + ri.(0, 4) * 15, fn _, cursor ->
          service = services_by_id[pick.(skills[staff_id])]

          if cursor + service.duration_min > h.end_min do
            cursor
          else
            start_min = cursor
            end_min = cursor + service.duration_min
            is_past = off < 0 or (off == 0 and end_min <= now_min)

            status =
              cond do
                is_past ->
                  roll = :rand.uniform()

                  cond do
                    roll < 0.86 -> "completed"
                    roll < 0.93 -> "no_show"
                    true -> "cancelled"
                  end

                :rand.uniform() < 0.5 ->
                  "confirmed"

                true ->
                  "booked"
              end

            source = if :rand.uniform() < 0.45, do: "online", else: "walk-in"

            ref = if source == "online", do: Blastek.Salon.new_booking_ref(), else: ""

            created = NaiveDateTime.new!(date, ~T[08:00:00])

            appt =
              Repo.insert!(%Appointment{
                booking_ref: ref,
                client_id: pick.(client_ids),
                staff_id: staff_id,
                service_id: service.id,
                date: date,
                start_min: start_min,
                end_min: end_min,
                status: status,
                price_cents: service.price_cents,
                source: source,
                venue_id: vid,
                inserted_at: created,
                updated_at: created
              })

            if status == "completed" do
              tip_rate = pick.([0, 0, 0.10, 0.15, 0.15, 0.20])
              tip_cents = round(service.price_cents * tip_rate)
              sold_at = NaiveDateTime.new!(date, Time.from_seconds_after_midnight(end_min * 60))

              sale =
                Repo.insert!(%Sale{
                  client_id: appt.client_id,
                  subtotal_cents: service.price_cents,
                  tip_cents: tip_cents,
                  total_cents: service.price_cents + tip_cents,
                  venue_id: vid,
                  payment_method: pick.(["card", "card", "card", "cash"]),
                  inserted_at: sold_at,
                  updated_at: sold_at
                })

              Repo.insert!(%SaleItem{
                sale_id: sale.id,
                appointment_id: appt.id,
                description: service.name,
                amount_cents: service.price_cents
              })
            end

            end_min + ri.(0, 3) * 15
          end
        end)
      end
    end

    config.reviews
    |> Enum.with_index()
    |> Enum.each(fn {{name, rating, comment}, i} ->
      at = NaiveDateTime.add(now, -(3 + i * 9) * 86_400, :second)

      Repo.insert!(%Review{
        client_name: name,
        rating: rating,
        comment: comment,
        venue_id: vid,
        inserted_at: at,
        updated_at: at
      })
    end)

    venue
  end

  # --------------------------------------------------------------------------
  # Venue 1 — Le Salon Anfa, Casablanca
  # --------------------------------------------------------------------------
  anfa =
    seed_venue.(%{
      name: "Le Salon Anfa",
      slug: "le-salon-anfa",
      tagline: "Hair, nails, barbering & massage in one studio",
      address: "27 Rue Aït Ourir, Gauthier, Casablanca",
      city: "Casablanca",
      phone: "+212 5 22 27 48 80",
      open_min: 540,
      close_min: 1080,
      day_range: -35..10,
      categories: [{"Hair", 1}, {"Barbering", 2}, {"Nails", 3}, {"Massage & Spa", 4}],
      services: [
        {:cut, "Hair", "Women's cut & style", "Consultation, shampoo, precision cut and finish",
         60, 250},
        {:blow, "Hair", "Blow dry & finish", "Wash and professional blow-out", 45, 150},
        {:color, "Hair", "Full color", "Single-process color, root to tip", 120, 600},
        {:balayage, "Hair", "Balayage", "Hand-painted highlights with toner", 150, 900},
        {:highlights, "Hair", "Partial highlights", "Foil highlights on the top section", 120,
         700},
        {:fade, "Barbering", "Skin fade", "Clipper fade with detailed finish", 45, 120},
        {:mens, "Barbering", "Classic men's cut", "Scissor or clipper cut with hot towel", 30,
         100},
        {:beard, "Barbering", "Beard trim & shape", "Trim, line-up and conditioning oil", 30, 70},
        {:combo, "Barbering", "Cut & beard combo", "Full cut plus beard sculpting", 60, 160},
        {:mani, "Nails", "Classic manicure", "Shape, cuticle care and polish", 45, 120},
        {:gel, "Nails", "Gel manicure", "Long-wear gel polish manicure", 60, 180},
        {:pedi, "Nails", "Spa pedicure", "Soak, exfoliation and polish", 60, 200},
        {:swedish, "Massage & Spa", "Swedish massage — 60 min", "Full-body relaxation massage",
         60, 400},
        {:deep, "Massage & Spa", "Deep tissue massage — 60 min",
         "Targeted pressure for tension relief", 60, 450},
        {:facial, "Massage & Spa", "Express facial", "Cleanse, exfoliate and hydrate", 30, 200}
      ],
      staff: [
        {:yasmine, "Yasmine El Amrani", "Senior stylist", "#7E2438"},
        {:salma, "Salma Idrissi", "Color specialist", "#C89C64"},
        {:reda, "Reda Benjelloun", "Barber", "#6E4B2A"},
        {:nadia, "Nadia Tazi", "Nail & spa therapist", "#4A1220"}
      ],
      skills: %{
        yasmine: [:cut, :blow, :color, :highlights, :mens],
        salma: [:color, :balayage, :highlights, :blow],
        reda: [:fade, :mens, :beard, :combo],
        nadia: [:mani, :gel, :pedi, :swedish, :deep, :facial]
      },
      # Studio closed Sunday; Reda off Monday; Yasmine off Wednesday.
      working: fn key, wd ->
        wd != 0 and not (key == :reda and wd == 1) and not (key == :yasmine and wd == 3)
      end,
      clients: [
        {"Leila", "Bennani", "Sensitive scalp — avoid ammonia color"},
        {"Youssef", "El Fassi", ""},
        {"Sara", "Alaoui", ""},
        {"Mehdi", "Berrada", ""},
        {"Imane", "Chraibi", "Allergic to acrylates (no acrylic nails)"},
        {"Omar", "Sqalli", ""},
        {"Kenza", "Lahlou", ""},
        {"Amine", "Tahiri", ""},
        {"Hajar", "Benkirane", ""},
        {"Karim", "Ziani", ""},
        {"Amal", "Drissi", "Latex allergy"},
        {"Anas", "Bouzoubaa", ""},
        {"Charlotte", "Moreau", ""},
        {"Adam", "El Mansouri", ""},
        {"Nour", "Kadiri", ""},
        {"Hicham", "Bennis", ""},
        {"Ghita", "Amrani", ""},
        {"Daniel", "Costa", ""}
      ],
      reviews: [
        {"Leila B.", 5,
         "Yasmine gave me the best cut I have had in years. Booking online took two minutes."},
        {"Hajar B.", 5,
         "Salma understood exactly what I wanted. The balayage matches the reference photo."},
        {"Mehdi B.", 5, "Reda is fast, precise, and the hot towel finish is a great touch."},
        {"Imane C.", 4,
         "Lovely gel manicure and they actually noted my acrylate allergy. One star off for the wait."},
        {"Omar S.", 5, "Deep tissue massage with Nadia fixed my desk-job shoulders."},
        {"Ghita A.", 5,
         "Spotless salon, calm atmosphere, and the reminders meant I did not forget my appointment."},
        {"Adam E.", 4, "Solid skin fade. Slightly pricey but worth it."},
        {"Nour K.", 5, "The express facial is the best value in Gauthier."},
        {"Daniel C.", 5, "Booked same-day and got in an hour later. Great experience."},
        {"Charlotte M.", 5, "Highlights look so natural. Already rebooked."}
      ]
    })

  # --------------------------------------------------------------------------
  # Venue 2 — Barber Corner, Rabat (a second tenant, fully independent)
  # --------------------------------------------------------------------------
  corner =
    seed_venue.(%{
      name: "Barber Corner",
      slug: "barber-corner",
      tagline: "Fades, beards and hot-towel shaves in Agdal",
      address: "12 Avenue de France, Agdal, Rabat",
      city: "Rabat",
      phone: "+212 5 37 67 12 45",
      open_min: 600,
      close_min: 1200,
      day_range: -21..7,
      categories: [{"Cuts", 1}, {"Beard & Shave", 2}],
      services: [
        {:fade, "Cuts", "Skin fade", "Clipper fade with sharp line-up", 45, 130},
        {:classic, "Cuts", "Classic cut", "Scissor cut and style", 30, 90},
        {:kids, "Cuts", "Kids' cut", "Under 12s", 30, 60},
        {:beard, "Beard & Shave", "Beard sculpt", "Trim, shape and beard oil", 30, 80},
        {:shave, "Beard & Shave", "Hot towel shave", "Traditional razor shave", 45, 120},
        {:combo, "Beard & Shave", "Cut & beard combo", "Full cut plus beard sculpting", 60, 180}
      ],
      staff: [
        {:hamza, "Hamza Ouazzani", "Master barber", "#2F4858"},
        {:ilyas, "Ilyas Bennis", "Barber", "#33658A"}
      ],
      skills: %{
        hamza: [:fade, :classic, :beard, :shave, :combo],
        ilyas: [:fade, :classic, :kids, :beard]
      },
      # Open every day except Sunday; Ilyas off Tuesday.
      working: fn key, wd -> wd != 0 and not (key == :ilyas and wd == 2) end,
      clients: [
        {"Rachid", "Alami", ""},
        {"Bilal", "Naciri", ""},
        {"Simo", "Cherkaoui", ""},
        {"Walid", "Fassi", ""},
        {"Tarik", "Ouali", ""},
        {"Zakaria", "Hakimi", ""},
        {"Nabil", "Saidi", "Sensitive skin — no alcohol aftershave"},
        {"Marouane", "Idrissi", ""}
      ],
      reviews: [
        {"Rachid A.", 5, "Best fade in Agdal, and Hamza never rushes."},
        {"Bilal N.", 5, "Booked from my phone at midnight for the next morning. Brilliant."},
        {"Tarik O.", 4, "Great shave. Gets busy on Saturdays."},
        {"Zakaria H.", 5, "Ilyas is great with my son — quick and patient."}
      ]
    })

  anfa_appts = Repo.aggregate(from(a in Appointment, where: a.venue_id == ^anfa.id), :count)
  corner_appts = Repo.aggregate(from(a in Appointment, where: a.venue_id == ^corner.id), :count)

  IO.puts("""
  Seeded 2 venues:
    #{anfa.name} (/#{anfa.slug}) — #{anfa_appts} appointments
    #{corner.name} (/#{corner.slug}) — #{corner_appts} appointments
  """)
end

# Demo accounts (separate guard so they seed even on an existing database).
if Repo.aggregate(Accounts.User, :count) == 0 do
  anfa = Venues.get_by_slug("le-salon-anfa")
  corner = Venues.get_by_slug("barber-corner")

  # Owner of Le Salon Anfa.
  {:ok, owner} =
    Accounts.sign_up(%{
      email: "owner@salonanfa.ma",
      password: "blastek123",
      first_name: "Yasmine",
      last_name: "El Amrani"
    })

  {:ok, _} = Venues.add_member(anfa.id, owner.id, "owner")

  # Owner of the second venue — proves the two dashboards are isolated.
  {:ok, barber} =
    Accounts.sign_up(%{
      email: "owner@barbercorner.ma",
      password: "blastek123",
      first_name: "Hamza",
      last_name: "Ouazzani"
    })

  {:ok, _} = Venues.add_member(corner.id, barber.id, "owner")

  # A customer with no venue access.
  {:ok, _} =
    Accounts.sign_up(%{
      email: "leila.bennani@example.com",
      password: "blastek123",
      first_name: "Leila",
      last_name: "Bennani"
    })

  IO.puts("""
  Demo accounts (password: blastek123)
    owner@salonanfa.ma      → owner of Le Salon Anfa
    owner@barbercorner.ma   → owner of Barber Corner
    leila.bennani@example.com → customer
  """)
end
