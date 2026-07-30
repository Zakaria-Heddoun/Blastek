defmodule Blastek.Venues.ServiceTemplate do
  @moduledoc "A starter service, offered during onboarding so nobody types their whole menu."
  use Ecto.Schema

  schema "service_templates" do
    field :catalog, :string
    field :category, :string
    field :name_i18n, :map, default: %{}
    field :duration_min, :integer
    field :price_hint_cents, :integer, default: 0
    field :sort, :integer, default: 0
  end

  @doc "The name in a locale, falling back to French and then to anything present."
  def name(%__MODULE__{name_i18n: names}, locale) do
    Map.get(names, to_string(locale)) || Map.get(names, "fr") ||
      names |> Map.values() |> List.first() || ""
  end
end

defmodule Blastek.Venues.Onboarding do
  @moduledoc """
  Self-serve venue creation (E5-T8, E5-T10 / F0.5).

  A wizard on a phone, in Arabic, over a patchy connection. Everything here
  follows from that:

    * **Every step is saved as it is completed.** `venues.onboarding` holds the
      step state, so a dead battery at step three resumes at step three rather
      than starting over. The venue row exists from the first step onward.
    * **The venue is usable before it is approved.** Status stays `pending`, the
      public page stays hidden, and the dashboard works — an owner can build
      their catalog and invite their team while an admin gets round to them.
    * **Schemaless state.** The wizard's shape will change far more often than
      the database should; a column per step would mean a migration per redesign.

  Approval is a human decision, so this exposes the queue and the two verbs, and
  keeps the reason when the answer is no.
  """
  import Ecto.Query

  alias Blastek.Accounts.Phone
  alias Blastek.Audit
  alias Blastek.Notifications
  alias Blastek.Repo
  alias Blastek.Venues
  alias Blastek.Venues.ServiceTemplate
  alias Blastek.Venues.Venue

  @steps ~w(basics category services team hours review)
  # After this long an unfinished venue is nobody's live business.
  @abandon_after_days 30

  def steps, do: @steps

  ## ---------- step state ----------

  @doc """
  Records progress through the wizard.

  `data` is merged into the step's slot rather than replacing the whole blob, so
  going back to fix step one cannot wipe step three.
  """
  def update_step(%Venue{} = venue, step, data) do
    step = to_string(step)

    if step in @steps do
      onboarding = venue.onboarding || %{}
      merged = Map.merge(Map.get(onboarding, step, %{}), stringify(data))

      next =
        onboarding
        |> Map.put(step, merged)
        |> Map.put("current_step", step)
        |> Map.put("completed", completed_steps(onboarding, step))
        |> Map.put("updated_at", NaiveDateTime.utc_now() |> NaiveDateTime.to_iso8601())

      Venues.update_venue(venue, %{onboarding: next})
    else
      {:error, "Unknown step."}
    end
  end

  defp completed_steps(onboarding, step) do
    onboarding |> Map.get("completed", []) |> List.wrap() |> Kernel.++([step]) |> Enum.uniq()
  end

  @doc "Whether every step has been completed."
  def complete?(%Venue{onboarding: onboarding}) do
    done = onboarding |> Kernel.||(%{}) |> Map.get("completed", []) |> List.wrap()
    Enum.all?(@steps -- ["review"], &(&1 in done))
  end

  ## ---------- submission and review ----------

  @doc """
  Hands a venue to the admin queue.

  Refuses a venue with no services: the point of review is to look at something,
  and an empty page tells an admin nothing.
  """
  def submit(%Venue{} = venue, actor \\ nil) do
    cond do
      venue.status == "active" ->
        {:error, "This venue is already live."}

      Repo.aggregate(from(s in Blastek.Salon.Service, where: s.venue_id == ^venue.id), :count) ==
          0 ->
        {:error, "Add at least one service before submitting."}

      true ->
        {:ok, updated} =
          Venues.update_venue(venue, %{
            onboarding: Map.put(venue.onboarding || %{}, "submitted_at", iso_now())
          })

        Audit.record("venue.submitted", %{
          venue_id: venue.id,
          actor: actor,
          subject_type: "venue",
          subject_id: venue.id
        })

        {:ok, updated}
    end
  end

  @doc "Venues waiting for a decision, oldest first — a queue, not a list."
  def review_queue do
    Repo.all(
      from v in Venue,
        where: v.status == "pending" and fragment("? \\? 'submitted_at'", v.onboarding),
        order_by: [asc: fragment("? ->> 'submitted_at'", v.onboarding)]
    )
  end

  @doc "Puts a venue live."
  def approve(venue_id, actor) do
    with %Venue{} = venue <- Venues.get_venue(venue_id),
         {:ok, updated} <- Venues.update_venue(venue, %{status: "active", rejected_reason: ""}) do
      Audit.record("venue.approved", %{
        venue_id: venue.id,
        actor: actor,
        subject_type: "venue",
        subject_id: venue.id
      })

      notify_owner(updated, :approved, "")
      {:ok, updated}
    else
      nil -> {:error, "Unknown venue."}
      other -> other
    end
  end

  @doc """
  Turns a venue down, with a reason.

  The reason is required. "Rejected" with no explanation produces a support
  conversation instead of a corrected listing.
  """
  def reject(venue_id, reason, actor) do
    reason = to_string(reason) |> String.trim()

    cond do
      reason == "" ->
        {:error, "Give a reason — the owner needs to know what to fix."}

      venue = Venues.get_venue(venue_id) ->
        {:ok, updated} =
          Venues.update_venue(venue, %{status: "pending", rejected_reason: reason})

        Audit.record("venue.rejected", %{
          venue_id: venue.id,
          actor: actor,
          subject_type: "venue",
          subject_id: venue.id,
          metadata: %{reason: reason}
        })

        notify_owner(updated, :rejected, reason)
        {:ok, updated}

      true ->
        {:error, "Unknown venue."}
    end
  end

  ## ---------- duplicate detection (E5-T10) ----------

  @doc """
  Venues that look like the same business as this one.

  A heuristic for the admin queue, not a block: two salons in one city really
  can share a name, and a franchise really does reuse a phone number. It flags
  and lets a human decide.

  Matches on a shared phone number, or on the same name in the same city — the
  two ways the same business gets entered twice.
  """
  def possible_duplicates(%Venue{} = venue) do
    phone = normalized_phone(venue.phone)
    name = normalize_text(venue.name)
    city = normalize_text(venue.city)

    query =
      from v in Venue,
        where: v.id != ^venue.id,
        where:
          (^phone != "" and fragment("regexp_replace(?, '[^0-9]', '', 'g')", v.phone) == ^phone) or
            (^name != "" and ^city != "" and
               fragment("lower(unaccent(trim(?)))", v.name) == ^name and
               fragment("lower(unaccent(trim(?)))", v.city) == ^city),
        order_by: [asc: v.id],
        limit: 5

    Repo.all(query)
  end

  ## ---------- housekeeping ----------

  @doc "Venues abandoned mid-wizard, for archiving."
  def abandoned(older_than_days \\ @abandon_after_days) do
    cutoff =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-older_than_days * 86_400, :second)
      |> NaiveDateTime.truncate(:second)

    Repo.all(
      from v in Venue,
        where:
          v.status == "pending" and v.updated_at < ^cutoff and
            not fragment("? \\? 'submitted_at'", v.onboarding)
    )
  end

  ## ---------- service template catalogs (E5-T7) ----------

  @doc "The starter catalogs on offer, with how many services each holds."
  def catalogs do
    Repo.all(
      from t in ServiceTemplate,
        group_by: t.catalog,
        order_by: [asc: t.catalog],
        select: %{catalog: t.catalog, service_count: count(t.id)}
    )
  end

  def templates_for(catalog) do
    Repo.all(
      from t in ServiceTemplate,
        where: t.catalog == ^catalog,
        order_by: [asc: t.sort, asc: t.id]
    )
  end

  @doc """
  Creates real services from chosen templates.

  Copied rather than referenced: a venue's prices and names are its own from the
  moment it opens, and a template that changes later must not silently rewrite
  somebody's menu.
  """
  def apply_templates(%Venue{} = venue, template_ids, locale \\ "fr") do
    templates =
      Repo.all(from t in ServiceTemplate, where: t.id in ^template_ids, order_by: t.sort)

    Repo.transaction(fn ->
      categories = ensure_categories(venue.id, Enum.map(templates, & &1.category) |> Enum.uniq())

      for template <- templates do
        {:ok, service} =
          Blastek.Salon.create_service(
            venue.id,
            %{
              category_id: Map.fetch!(categories, template.category),
              name: ServiceTemplate.name(template, locale),
              duration_min: template.duration_min,
              price_cents: template.price_hint_cents
            },
            nil
          )

        service
      end
    end)
  end

  defp ensure_categories(venue_id, names) do
    existing =
      Repo.all(from c in Blastek.Salon.Category, where: c.venue_id == ^venue_id)
      |> Map.new(&{&1.name, &1.id})

    Enum.reduce(names, existing, fn name, acc ->
      case Map.fetch(acc, name) do
        {:ok, _id} ->
          acc

        :error ->
          {:ok, category} =
            Blastek.Salon.create_category(venue_id, %{name: name, sort: map_size(acc)})

          Map.put(acc, name, category.id)
      end
    end)
  end

  ## ---------- internals ----------

  defp notify_owner(venue, decision, reason) do
    case owner_contact(venue.id) do
      nil ->
        :ok

      to ->
        Notifications.deliver_venue_decision(to, venue.name, decision, reason,
          locale: Blastek.Venues.Settings.get(venue.settings, :locale)
        )
    end
  end

  defp owner_contact(venue_id) do
    Repo.one(
      from m in Blastek.Venues.VenueMember,
        join: u in assoc(m, :user),
        where: m.venue_id == ^venue_id and m.role == "owner",
        order_by: [asc: m.id],
        limit: 1,
        # A phone-first owner has no email, an email-first one has no phone;
        # whichever exists is where the decision goes.
        select: fragment("coalesce(nullif(?, ''), ?)", u.phone, u.email)
    )
  end

  defp normalized_phone(phone) do
    case Phone.normalize(phone) do
      {:ok, normalized} -> String.replace(normalized, ~r/\D/, "")
      _ -> phone |> to_string() |> String.replace(~r/\D/, "")
    end
  end

  defp normalize_text(value), do: value |> to_string() |> String.trim() |> String.downcase()

  defp iso_now, do: NaiveDateTime.utc_now() |> NaiveDateTime.to_iso8601()

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp stringify(other), do: other
end
