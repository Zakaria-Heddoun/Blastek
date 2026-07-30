defmodule Blastek.Salon do
  @moduledoc """
  The salon domain: catalog, team, clients, appointments, availability,
  checkout and reporting.

  Every public function takes `venue_id` as its first argument and scopes its
  queries through `Blastek.Scope` — see that module for why. Callers get the
  venue from the request context (membership for dashboard operations, slug for
  public ones); it is never taken from user-supplied arguments.
  """
  import Ecto.Query
  import Blastek.Scope

  alias Blastek.Repo
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

  @slot_step 15
  @appt_preloads [:client, :service, :staff]

  ## ---------- catalog ----------

  def list_categories(venue_id) do
    Repo.all(from c in scope(Category, venue_id), order_by: [c.sort, c.id])
  end

  def create_category(venue_id, attrs) do
    %Category{}
    |> Category.changeset(Map.put(attrs, :venue_id, venue_id))
    |> Repo.insert()
    |> reindexed(venue_id)
  end

  def list_services(venue_id, opts \\ []) do
    q = from s in scope(Service, venue_id), order_by: [s.category_id, s.id], preload: [:staff]
    q = if opts[:active_only], do: from(s in q, where: s.active), else: q
    Repo.all(q)
  end

  def get_service!(venue_id, id) do
    get_scoped!(Repo, Service, id, venue_id) |> Repo.preload(:staff)
  end

  def create_service(venue_id, attrs, staff_ids) do
    %Service{}
    |> Service.changeset(Map.put(attrs, :venue_id, venue_id))
    |> put_staff(venue_id, staff_ids)
    |> Repo.insert()
    |> reindexed(venue_id)
  end

  def update_service(venue_id, id, attrs, staff_ids) do
    get_service!(venue_id, id)
    |> Service.changeset(attrs)
    |> put_staff(venue_id, staff_ids)
    |> Repo.update()
    |> reindexed(venue_id)
  end

  # The catalog is half of what a venue is findable by, so every catalog write
  # refreshes the search document. One funnel instead of a `reindex_venue` call
  # remembered at each site — the same reason writes go through `Scope`.
  defp reindexed({:ok, _record} = result, venue_id) do
    Blastek.Discovery.reindex_venue(venue_id)
    result
  end

  defp reindexed(result, _venue_id), do: result

  defp put_staff(changeset, _venue_id, nil), do: changeset

  defp put_staff(changeset, venue_id, staff_ids) do
    # Scoped so a caller cannot attach another venue's staff to their service.
    staff = Repo.all(from s in scope(Staff, venue_id), where: s.id in ^staff_ids)
    Ecto.Changeset.put_assoc(changeset, :staff, staff)
  end

  ## ---------- team ----------

  def list_staff(venue_id, opts \\ []) do
    q = from s in scope(Staff, venue_id), order_by: s.id, preload: [:hours, :services]
    q = if opts[:active_only], do: from(s in q, where: s.active), else: q
    Repo.all(q)
  end

  def get_staff!(venue_id, id) do
    get_scoped!(Repo, Staff, id, venue_id) |> Repo.preload([:hours, :services])
  end

  def create_staff(venue_id, attrs, hours, service_ids) do
    Repo.transaction(fn ->
      {:ok, staff} =
        %Staff{}
        |> Staff.changeset(Map.put(attrs, :venue_id, venue_id))
        |> Repo.insert()

      default_hours =
        for wd <- 0..6,
            do: %{
              staff_id: staff.id,
              weekday: wd,
              working: wd != 0,
              start_min: 540,
              end_min: 1080
            }

      Repo.insert_all(StaffHour, default_hours)
      apply_staff_details(venue_id, staff, hours, service_ids)
      get_staff!(venue_id, staff.id)
    end)
  end

  def update_staff(venue_id, id, attrs, hours, service_ids) do
    Repo.transaction(fn ->
      staff = get_staff!(venue_id, id)
      {:ok, staff} = staff |> Staff.changeset(attrs) |> Repo.update()
      apply_staff_details(venue_id, staff, hours, service_ids)
      get_staff!(venue_id, staff.id)
    end)
  end

  defp apply_staff_details(venue_id, staff, hours, service_ids) do
    for h <- hours || [] do
      Repo.update_all(
        from(sh in StaffHour, where: sh.staff_id == ^staff.id and sh.weekday == ^h.weekday),
        set: [working: h.working, start_min: h.start_min, end_min: h.end_min]
      )
    end

    if service_ids do
      # Only this venue's services may be linked.
      valid_ids =
        Repo.all(from s in scope(Service, venue_id), where: s.id in ^service_ids, select: s.id)

      Repo.delete_all(from ss in "staff_services", where: ss.staff_id == ^staff.id)
      rows = Enum.map(valid_ids, &%{staff_id: staff.id, service_id: &1})
      Repo.insert_all("staff_services", rows)
    end
  end

  ## ---------- clients ----------

  @doc """
  Clients of a venue, searchable and paginated.

  `staff_id:` narrows the list to the people that staff member has actually
  served — the "limited CRM" a `staff` role gets (F0.3). A stylist needs the
  allergy note for the person in their chair; they do not need the venue's whole
  customer list, which is the venue's commercial asset and walks out of the door
  with anyone who leaves.
  """
  def list_clients(venue_id, query_text, opts \\ []) do
    term = "%#{String.downcase(query_text || "")}%"
    limit = opts[:limit] || 50
    offset = opts[:offset] || 0

    Repo.all(
      from c in search_clients(venue_id, term, opts[:staff_id]),
        order_by: [c.first_name, c.last_name],
        limit: ^limit,
        offset: ^offset
    )
  end

  def count_clients(venue_id, query_text, opts \\ []) do
    term = "%#{String.downcase(query_text || "")}%"
    Repo.aggregate(search_clients(venue_id, term, opts[:staff_id]), :count)
  end

  # The `:client` binding is named here so the `served_by` subquery can
  # correlate back to it.
  defp client_base(venue_id), do: from(c in Client, as: :client) |> scope(venue_id)

  defp search_clients(venue_id, term, staff_id) do
    query =
      from c in client_base(venue_id),
        where:
          like(
            fragment(
              "lower(? || ' ' || ? || ' ' || ? || ' ' || ?)",
              c.first_name,
              c.last_name,
              c.email,
              c.phone
            ),
            ^term
          )

    if staff_id, do: served_by(query, staff_id), else: query
  end

  # `:none` is a staff member with no calendar column — they have served nobody.
  # Spelled out rather than left to `nil`, which every other option here means
  # "unrestricted".
  defp served_by(query, :none), do: from(c in query, where: false)

  # EXISTS rather than a join: a client with twenty appointments is still one
  # row in the list.
  defp served_by(query, staff_id) do
    from c in query,
      where:
        exists(
          from a in Appointment,
            where: a.client_id == parent_as(:client).id and a.staff_id == ^staff_id,
            select: 1
        )
  end

  @doc """
  One client with their recent appointments.

  `staff_id:` restricts both the lookup and the history, so a staff member
  cannot reach a colleague's client by guessing an id, and sees only their own
  appointments with the ones they do serve.
  """
  def get_client!(venue_id, id, opts \\ []) do
    staff_id = opts[:staff_id]

    base = client_base(venue_id)
    query = if staff_id, do: served_by(base, staff_id), else: base

    case Repo.get(query, id) do
      nil -> raise Ecto.NoResultsError, queryable: Client
      client -> Repo.preload(client, appointments: client_history(staff_id))
    end
  end

  defp client_history(staff_id) do
    query =
      from a in Appointment,
        order_by: [desc: a.date, desc: a.start_min],
        limit: 50,
        preload: ^@appt_preloads

    if staff_id, do: from(a in query, where: a.staff_id == ^staff_id), else: query
  end

  @doc """
  Appointment counts and lifetime spend for many clients in two queries.

  Resolved per-client this used to issue 2N+1 queries for the clients list;
  the GraphQL layer batches ids through here instead.
  """
  def client_stats_for(venue_id, client_ids) do
    counts =
      Repo.all(
        from a in scope(Appointment, venue_id),
          where: a.client_id in ^client_ids,
          group_by: a.client_id,
          select: {a.client_id, count(a.id)}
      )
      |> Map.new()

    spend =
      Repo.all(
        from s in scope(Sale, venue_id),
          where: s.client_id in ^client_ids,
          group_by: s.client_id,
          select: {s.client_id, coalesce(sum(s.total_cents), 0)}
      )
      |> Map.new()

    Map.new(client_ids, fn id ->
      {id, %{appt_count: Map.get(counts, id, 0), total_spent_cents: Map.get(spend, id, 0)}}
    end)
  end

  def client_stats(venue_id, client_id) do
    client_stats_for(venue_id, [client_id])[client_id]
  end

  def create_client(venue_id, attrs), do: find_or_create_client(venue_id, attrs)

  def update_client(venue_id, id, attrs) do
    get_scoped!(Repo, Client, id, venue_id) |> Client.changeset(attrs) |> Repo.update()
  end

  @doc """
  Finds a client of this venue by email (or by linked user account), creating
  one when absent. Matching is per-venue: the same person is a separate client
  record at each salon, as their history and notes are venue-private.
  """
  def find_or_create_client(venue_id, attrs) do
    attrs = Map.put(attrs, :venue_id, venue_id)
    email = attrs |> Map.get(:email, "") |> to_string() |> String.trim() |> String.downcase()
    user_id = Map.get(attrs, :user_id)

    existing =
      cond do
        user_id ->
          Repo.one(from c in scope(Client, venue_id), where: c.user_id == ^user_id, limit: 1)

        email != "" ->
          Repo.one(
            from c in scope(Client, venue_id),
              where: fragment("lower(?)", c.email) == ^email,
              limit: 1
          )

        true ->
          nil
      end

    case existing do
      nil ->
        insert_client(venue_id, attrs, user_id)

      client ->
        # Link an existing walk-in record to the account on first online booking.
        if user_id && is_nil(client.user_id) do
          client |> Client.changeset(%{user_id: user_id}) |> Repo.update()
        else
          {:ok, client}
        end
    end
  end

  # Two concurrent requests can both miss the lookup above; the unique index on
  # (venue_id, user_id) fails the loser, whose caller wants the winner's row,
  # not an error.
  defp insert_client(venue_id, attrs, user_id) do
    case %Client{} |> Client.changeset(attrs) |> Repo.insert() do
      {:ok, client} ->
        {:ok, client}

      {:error, _changeset} = error ->
        raced =
          user_id &&
            Repo.one(from c in scope(Client, venue_id), where: c.user_id == ^user_id, limit: 1)

        if raced, do: {:ok, raced}, else: error
    end
  end

  @doc "Every client record across venues for one marketplace account."
  def list_client_ids_for_user(user_id) do
    Repo.all(from c in Client, where: c.user_id == ^user_id, select: c.id)
  end

  ## ---------- appointments ----------

  def list_appointments(venue_id, from_date, to_date, opts \\ []) do
    q =
      from a in scope(Appointment, venue_id),
        where: a.date >= ^from_date and a.date <= ^to_date,
        order_by: [a.date, a.start_min],
        preload: ^@appt_preloads

    # Staff-role members only see their own column.
    q = if opts[:staff_id], do: from(a in q, where: a.staff_id == ^opts[:staff_id]), else: q
    Repo.all(q)
  end

  def get_appointment!(venue_id, id) do
    get_scoped!(Repo, Appointment, id, venue_id) |> Repo.preload(@appt_preloads)
  end

  @doc """
  Fetches one appointment owned by any of the given client records, or nil.
  Scoped by ownership rather than venue — a customer's own bookings span venues.
  """
  def get_appointment_for_client(id, client_ids) do
    Repo.one(
      from a in Appointment,
        where: a.id == ^id and a.client_id in ^client_ids,
        preload: ^@appt_preloads
    )
  end

  def create_appointment(venue_id, args) do
    service = get_service!(venue_id, args.service_id)
    start_min = args.start_min
    end_min = start_min + service.duration_min

    with {:ok, staff} <- fetch_staff(venue_id, args.staff_id),
         {:ok, client_id} <- resolve_client_id(venue_id, args),
         :ok <- check_clash(venue_id, staff.id, args.date, start_min, end_min, nil) do
      %Appointment{}
      |> Appointment.changeset(%{
        venue_id: venue_id,
        client_id: client_id,
        staff_id: staff.id,
        service_id: service.id,
        date: args.date,
        start_min: start_min,
        end_min: end_min,
        price_cents: service.price_cents,
        notes: args[:notes] || "",
        source: "walk-in"
      })
      |> Repo.insert()
      |> preload_result()
    end
  end

  def update_appointment(venue_id, id, args) do
    appt = get_appointment!(venue_id, id)

    next = %{
      status: args[:status] || appt.status,
      date: args[:date] || appt.date,
      staff_id: args[:staff_id] || appt.staff_id,
      start_min: args[:start_min] || appt.start_min,
      notes: args[:notes] || appt.notes,
      price_cents: args[:price_cents] || appt.price_cents
    }

    next = Map.put(next, :end_min, next.start_min + (appt.end_min - appt.start_min))

    moved =
      next.date != appt.date or next.start_min != appt.start_min or
        next.staff_id != appt.staff_id

    # A cancelled/no-show appointment does not occupy its slot, so bringing one
    # back to life must re-check the slot even when nothing moved.
    reactivated =
      appt.status in ["cancelled", "no_show"] and
        next.status not in ["cancelled", "no_show"]

    with {:ok, _staff} <- fetch_staff(venue_id, next.staff_id),
         :ok <- maybe_check_clash(venue_id, appt, next, moved or reactivated) do
      appt |> Appointment.changeset(next) |> Repo.update() |> preload_result()
    end
  end

  # Only a change into a slot the appointment will actually occupy can clash;
  # cancelling or marking a no-show frees the slot instead.
  defp maybe_check_clash(venue_id, appt, next, takes_slot?) do
    if takes_slot? and next.status not in ["cancelled", "no_show"] do
      check_clash(venue_id, next.staff_id, next.date, next.start_min, next.end_min, appt.id)
    else
      :ok
    end
  end

  defp fetch_staff(venue_id, staff_id) do
    case get_scoped(Repo, Staff, staff_id, venue_id) do
      nil -> {:error, "Unknown staff member."}
      staff -> {:ok, staff}
    end
  end

  defp resolve_client_id(venue_id, %{client_id: id}) when not is_nil(id) do
    case get_scoped(Repo, Client, id, venue_id) do
      nil -> {:error, "Unknown client."}
      client -> {:ok, client.id}
    end
  end

  defp resolve_client_id(venue_id, %{client: attrs}) when is_map(attrs) do
    with {:ok, client} <- find_or_create_client(venue_id, attrs), do: {:ok, client.id}
  end

  defp resolve_client_id(_venue_id, _), do: {:error, "client details required"}

  defp check_clash(venue_id, staff_id, date, start_min, end_min, exclude_id) do
    q =
      from a in scope(Appointment, venue_id),
        join: c in assoc(a, :client),
        where:
          a.staff_id == ^staff_id and a.date == ^date and
            a.status not in ["cancelled", "no_show"] and
            a.start_min < ^end_min and a.end_min > ^start_min,
        select: c.first_name,
        limit: 1

    q = if exclude_id, do: from(a in q, where: a.id != ^exclude_id), else: q

    case Repo.one(q) do
      nil -> :ok
      name -> {:error, "That time overlaps #{name}'s appointment. Pick another slot."}
    end
  end

  defp preload_result({:ok, appt}), do: {:ok, Repo.preload(appt, @appt_preloads, force: true)}
  defp preload_result(other), do: other

  ## ---------- availability ----------

  def availability(venue_id, service_ids, staff_id, date) do
    services = Repo.all(from s in scope(Service, venue_id), where: s.id in ^service_ids)
    by_id = Map.new(services, &{&1.id, &1})

    cond do
      Enum.any?(service_ids, &(not Map.has_key?(by_id, &1))) ->
        {:error, "unknown service"}

      true ->
        # Summed per requested id, not per distinct service, so booking the
        # same treatment twice reserves twice the time.
        total = Enum.sum(Enum.map(service_ids, &by_id[&1].duration_min))

        candidates =
          case staff_id do
            nil -> eligible_staff(venue_id, service_ids)
            "any" -> eligible_staff(venue_id, service_ids)
            id -> scoped_staff_candidate(venue_id, id)
          end

        slots =
          candidates
          |> Enum.flat_map(fn st ->
            slots_for_staff(venue_id, st.id, date, total) |> Enum.map(&{&1, st.id})
          end)
          |> Enum.sort()
          |> Enum.uniq_by(fn {start, _} -> start end)
          |> Enum.map(fn {start, sid} -> %{start_min: start, staff_id: sid} end)

        {:ok, %{total_duration: total, slots: slots}}
    end
  end

  # A staff id from user input is only honored if it belongs to this venue.
  defp scoped_staff_candidate(venue_id, id) do
    case get_scoped(Repo, Staff, to_int(id), venue_id) do
      nil -> []
      staff -> [%{id: staff.id}]
    end
  end

  defp to_int(v) when is_integer(v), do: v
  defp to_int(v), do: String.to_integer(to_string(v))

  def eligible_staff(venue_id, service_ids) do
    n = length(Enum.uniq(service_ids))

    Repo.all(
      from s in scope(Staff, venue_id),
        join: ss in "staff_services",
        on: ss.staff_id == s.id,
        where: s.active and ss.service_id in ^service_ids,
        group_by: s.id,
        having: count(fragment("DISTINCT ?", ss.service_id)) == ^n,
        select: %{id: s.id, name: s.name}
    )
  end

  def slots_for_staff(venue_id, staff_id, date, duration_min) do
    weekday = Date.day_of_week(date, :sunday) - 1

    hour =
      Repo.one(
        from h in StaffHour,
          join: s in Staff,
          on: s.id == h.staff_id and s.venue_id == ^venue_id,
          where: h.staff_id == ^staff_id and h.weekday == ^weekday and h.working
      )

    if hour == nil do
      []
    else
      busy =
        Repo.all(
          from a in scope(Appointment, venue_id),
            where:
              a.staff_id == ^staff_id and a.date == ^date and
                a.status not in ["cancelled", "no_show"],
            select: {a.start_min, a.end_min}
        )

      now = NaiveDateTime.local_now()

      min_start =
        if Date.compare(date, NaiveDateTime.to_date(now)) == :eq,
          do: now.hour * 60 + now.minute,
          else: -1

      hour.start_min
      |> Stream.iterate(&(&1 + @slot_step))
      |> Enum.take_while(&(&1 + duration_min <= hour.end_min))
      |> Enum.filter(fn start ->
        start > min_start and
          not Enum.any?(busy, fn {bs, be} -> start < be and start + duration_min > bs end)
      end)
    end
  end

  ## ---------- online booking ----------

  @doc """
  Books a slot for a client.

  Availability is checked inside a transaction holding a per-(venue, staff,
  date) advisory lock, and the appointments table carries an exclusion
  constraint as the real guarantee — between the check and the insert another
  request can otherwise win the same slot.
  """
  def book(venue_id, args) do
    staff_arg = args[:staff_id] || "any"

    Repo.transaction(fn ->
      case availability(venue_id, args.service_ids, staff_arg, args.date) do
        {:ok, %{slots: slots}} ->
          case Enum.find(slots, &(&1.start_min == args.start_min)) do
            nil ->
              Repo.rollback(slot_taken())

            %{staff_id: staff_id} ->
              lock_staff_day(staff_id, args.date)

              # Re-check under the lock: the winner of a race sees the loser's
              # row, which the first check (taken before the lock) could not.
              case availability(venue_id, args.service_ids, to_string(staff_id), args.date) do
                {:ok, %{slots: fresh}} ->
                  if Enum.any?(fresh, &(&1.start_min == args.start_min)) do
                    insert_booking(venue_id, args, staff_id)
                  else
                    Repo.rollback(slot_taken())
                  end

                {:error, reason} ->
                  Repo.rollback(reason)
              end
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp slot_taken, do: "That time was just taken — please pick another slot."

  # Serializes concurrent bookings for the same staff member and day. Released
  # when the transaction ends. Staff ids are globally unique, so (staff_id,
  # day-number) is a collision-free key — a hashed key would occasionally
  # serialize unrelated bookings.
  @lock_epoch ~D[2020-01-01]
  defp lock_staff_day(staff_id, date) do
    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [staff_id, Date.diff(date, @lock_epoch)])
  end

  defp insert_booking(venue_id, args, staff_id) do
    ref = new_booking_ref()

    {appointments, end_min} =
      Enum.map_reduce(args.service_ids, args.start_min, fn sid, cursor ->
        service = get_service!(venue_id, sid)

        appt =
          %Appointment{}
          |> Appointment.changeset(%{
            venue_id: venue_id,
            booking_ref: ref,
            client_id: args.client_id,
            staff_id: staff_id,
            service_id: sid,
            date: args.date,
            start_min: cursor,
            end_min: cursor + service.duration_min,
            price_cents: service.price_cents,
            notes: args[:notes] || "",
            source: "online"
          })
          |> Repo.insert()
          |> case do
            {:ok, appt} -> appt
            # The exclusion constraint fired: someone booked between our check
            # and this insert. Roll the whole booking back.
            {:error, _changeset} -> Repo.rollback(slot_taken())
          end

        {Repo.preload(appt, @appt_preloads), cursor + service.duration_min}
      end)

    staff = get_staff!(venue_id, staff_id)

    %{
      booking_ref: ref,
      date: args.date,
      start_min: args.start_min,
      end_min: end_min,
      staff_name: staff.name,
      appointments: appointments
    }
  end

  @doc """
  A customer-facing booking reference. Random rather than timestamp-derived,
  which collided whenever two bookings landed in the same millisecond; the
  unique index on `appointments.booking_ref` is the backstop.
  """
  def new_booking_ref do
    "BK-" <> (:crypto.strong_rand_bytes(5) |> Base.encode32(padding: false) |> binary_part(0, 6))
  end

  ## ---------- checkout & sales ----------

  def checkout(venue_id, appointment_ids, tip_cents, payment_method) do
    appts =
      Repo.all(
        from a in scope(Appointment, venue_id),
          where: a.id in ^appointment_ids,
          preload: [:service]
      )

    cond do
      appts == [] ->
        {:error, "appointments not found"}

      # A completed appointment already has a sale — checking it out again
      # would record the revenue twice (double-click, retried request).
      Enum.any?(appts, &(&1.status == "completed")) ->
        {:error, "This appointment has already been checked out."}

      true ->
        do_checkout(venue_id, appts, tip_cents, payment_method)
    end
  end

  defp do_checkout(venue_id, appts, tip_cents, payment_method) do
    subtotal_cents = Enum.sum(Enum.map(appts, & &1.price_cents))
    tip_cents = tip_cents || 0

    Repo.transaction(fn ->
      {:ok, sale} =
        %Sale{}
        |> Sale.changeset(%{
          venue_id: venue_id,
          client_id: hd(appts).client_id,
          subtotal_cents: subtotal_cents,
          tip_cents: tip_cents,
          total_cents: subtotal_cents + tip_cents,
          payment_method: payment_method || "card"
        })
        |> Repo.insert()

      for a <- appts do
        Repo.insert!(%SaleItem{
          sale_id: sale.id,
          appointment_id: a.id,
          description: a.service.name,
          amount_cents: a.price_cents
        })

        Repo.update_all(from(x in Appointment, where: x.id == ^a.id),
          set: [status: "completed"]
        )
      end

      Repo.preload(sale, [:items, :client])
    end)
  end

  def list_sales(venue_id, from_date, opts \\ []) do
    limit = opts[:limit] || 50
    offset = opts[:offset] || 0

    Repo.all(
      from s in sales_since(venue_id, from_date),
        order_by: [desc: s.inserted_at],
        limit: ^limit,
        offset: ^offset,
        preload: [:items, :client]
    )
  end

  def count_sales(venue_id, from_date) do
    Repo.aggregate(sales_since(venue_id, from_date), :count)
  end

  defp sales_since(venue_id, from_date) do
    from s in scope(Sale, venue_id), where: fragment("?::date", s.inserted_at) >= ^from_date
  end

  ## ---------- reports ----------

  def report_summary(venue_id, days) do
    cutoff = Date.add(Date.utc_today(), -days)

    totals =
      Repo.one(
        from s in scope(Sale, venue_id),
          where: fragment("?::date", s.inserted_at) >= ^cutoff,
          select: %{
            revenue_cents: coalesce(sum(s.total_cents), 0),
            tips_cents: coalesce(sum(s.tip_cents), 0),
            sales_count: count(s.id)
          }
      )

    appt_stats =
      Repo.one(
        from a in scope(Appointment, venue_id),
          where: a.date >= ^cutoff,
          select: %{
            completed: filter(count(a.id), a.status == "completed"),
            no_shows: filter(count(a.id), a.status == "no_show"),
            cancelled: filter(count(a.id), a.status == "cancelled"),
            online: filter(count(a.id), a.source == "online"),
            total: count(a.id)
          }
      )

    revenue_by_day =
      Repo.all(
        from s in scope(Sale, venue_id),
          where: fragment("?::date", s.inserted_at) >= ^cutoff,
          group_by: fragment("?::date", s.inserted_at),
          order_by: fragment("?::date", s.inserted_at),
          select: %{day: fragment("?::date", s.inserted_at), revenue_cents: sum(s.total_cents)}
      )

    top_services =
      Repo.all(
        from si in SaleItem,
          join: s in Sale,
          on: s.id == si.sale_id and s.venue_id == ^venue_id,
          where: fragment("?::date", s.inserted_at) >= ^cutoff,
          group_by: si.description,
          order_by: [desc: sum(si.amount_cents)],
          limit: 6,
          select: %{
            name: si.description,
            count: count(si.id),
            revenue_cents: sum(si.amount_cents)
          }
      )

    top_staff =
      Repo.all(
        from a in scope(Appointment, venue_id),
          join: st in assoc(a, :staff),
          where: a.status == "completed" and a.date >= ^cutoff,
          group_by: [st.id, st.name, st.color],
          order_by: [desc: sum(a.price_cents)],
          select: %{
            name: st.name,
            color: st.color,
            count: count(a.id),
            revenue_cents: sum(a.price_cents)
          }
      )

    new_clients =
      Repo.aggregate(
        from(c in scope(Client, venue_id), where: fragment("?::date", c.inserted_at) >= ^cutoff),
        :count
      )

    %{
      days: days,
      revenue_cents: totals.revenue_cents,
      tips_cents: totals.tips_cents,
      sales_count: totals.sales_count,
      appointments: appt_stats,
      new_clients: new_clients,
      revenue_by_day: revenue_by_day,
      top_services: top_services,
      top_staff: top_staff
    }
  end

  ## ---------- venue (public) ----------

  @doc """
  Rating, review count and cheapest active service for many venues at once.

  Marketplace listings show these per card; resolved per venue it would be
  3N queries for a results page, so the GraphQL layer batches ids through here.
  """
  def venue_cards_for(venue_ids) do
    ratings =
      Repo.all(
        from r in Review,
          where: r.venue_id in ^venue_ids,
          group_by: r.venue_id,
          select: {r.venue_id, {avg(r.rating), count(r.id)}}
      )
      |> Map.new()

    price_from =
      Repo.all(
        from s in Service,
          where: s.venue_id in ^venue_ids and s.active,
          group_by: s.venue_id,
          select: {s.venue_id, min(s.price_cents)}
      )
      |> Map.new()

    Map.new(venue_ids, fn id ->
      {avg, count} = Map.get(ratings, id, {nil, 0})

      {id,
       %{
         rating: if(avg, do: avg |> Decimal.to_float() |> Float.round(1), else: 0.0),
         review_count: count,
         price_from_cents: Map.get(price_from, id)
       }}
    end)
  end

  @doc "Public marketplace view of one venue."
  def venue_view(%Venues.Venue{} = venue) do
    venue_id = venue.id
    reviews = Repo.all(from r in scope(Review, venue_id), order_by: [desc: r.inserted_at])

    rating =
      case reviews do
        [] -> 0.0
        _ -> Float.round(Enum.sum(Enum.map(reviews, & &1.rating)) / length(reviews), 1)
      end

    hours =
      for wd <- 0..6 do
        row =
          Repo.one(
            from h in StaffHour,
              join: s in Staff,
              on: s.id == h.staff_id and s.venue_id == ^venue_id,
              where: h.weekday == ^wd and h.working and s.active,
              select: %{open: min(h.start_min), close: max(h.end_min)}
          )

        %{weekday: wd, open: row && row.open, close: row && row.close}
      end

    %{
      id: venue.id,
      slug: venue.slug,
      city: venue.city,
      status: venue.status,
      lat: venue.lat,
      lng: venue.lng,
      # Venue-declared facts, stored in the settings JSONB rather than as
      # columns so a venue can list anything without a migration.
      amenities: venue.settings |> Map.get("amenities", []) |> List.wrap(),
      women_only: venue.settings |> Map.get("women_only", false) |> to_boolean(),
      photos: Blastek.Media.list_photos(venue_id),
      settings: %{
        business_name: venue.name,
        business_tagline: venue.tagline,
        business_address: venue.address,
        business_phone: venue.phone
      },
      categories: list_categories(venue_id),
      services: list_services(venue_id, active_only: true),
      staff: list_staff(venue_id, active_only: true),
      reviews: reviews,
      rating: rating,
      hours: hours,
      stats: %{
        bookings:
          Repo.aggregate(
            from(a in scope(Appointment, venue_id), where: a.status == "completed"),
            :count
          ),
        professionals: Repo.aggregate(from(s in scope(Staff, venue_id), where: s.active), :count),
        services: Repo.aggregate(from(s in scope(Service, venue_id), where: s.active), :count)
      }
    }
  end

  # Settings arrive from JSONB, where a flag may have been written as a boolean
  # or as a string depending on which client wrote it.
  defp to_boolean(true), do: true
  defp to_boolean("true"), do: true
  defp to_boolean(_), do: false

  @doc "Appointments belonging to a marketplace account, newest first, across venues."
  def list_my_appointments(client_ids) do
    Repo.all(
      from a in Appointment,
        where: a.client_id in ^client_ids,
        order_by: [desc: a.date, desc: a.start_min],
        limit: 100,
        preload: ^@appt_preloads
    )
  end
end
