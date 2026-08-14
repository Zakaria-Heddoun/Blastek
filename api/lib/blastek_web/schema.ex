defmodule BlastekWeb.Schema do
  @moduledoc """
  GraphQL schema for the Blastek salon platform.

  Two audiences share this schema:

    * the **marketplace** — public reads addressed by venue slug, plus a
      signed-in customer's own bookings;
    * the **dashboard** — venue-scoped reads and writes, authorized by the
      caller's membership. Dashboard resolvers take the venue from
      `context.venue_id` (see `BlastekWeb.AuthContext`) and never from an
      argument, so a caller cannot reach a venue it does not belong to.
  """
  use Absinthe.Schema
  import Absinthe.Resolution.Helpers, only: [batch: 3]
  import_types(Absinthe.Type.Custom)

  alias Blastek.Accounts
  alias Blastek.Audit
  alias Blastek.Discovery
  alias Blastek.I18n
  alias Blastek.Media
  alias Blastek.Notifications
  alias Blastek.Repo
  alias Blastek.Salon
  alias Blastek.Venues
  alias Blastek.Venues.Invitations

  alias BlastekWeb.Schema.{
    RateLimitAuth,
    RateLimitOtp,
    RequireAdmin,
    RequireAuth,
    RequireMember
  }

  # A quarter is more than any calendar view needs and keeps one request from
  # pulling a venue's entire history.
  @max_calendar_days 92

  ## ---------- objects ----------

  object :settings do
    field :business_name, :string

    @desc "Marketing copy, in the reader's language where the venue has written one."
    field :business_tagline, :string do
      resolve(fn settings, _, %{context: ctx} ->
        {:ok, I18n.translate(taglinable(settings), :tagline, ctx[:locale])}
      end)
    end

    field :business_address, :string
    field :business_phone, :string
  end

  object :category do
    field :id, :id

    @desc "In the reader's language, falling back to French and then to what the owner typed."
    field :name, :string do
      resolve(localized(:name))
    end

    @desc """
    Every locale's values, for the catalog editor (E7-T7).

    French appears here too even though it lives in the base columns — the
    editor thinks in tabs and should not have to know that one of them is
    stored differently.
    """
    field :translations, :json do
      resolve(translations_of(Blastek.Salon.Category))
    end

    field :sort, :integer
  end

  object :service do
    field :id, :id
    field :category_id, :id

    @desc "In the reader's language, falling back to French and then to what the owner typed."
    field :name, :string do
      resolve(localized(:name))
    end

    field :description, :string do
      resolve(localized(:description))
    end

    @desc "Every locale's values, for the catalog editor (E7-T7)."
    field :translations, :json do
      resolve(translations_of(Blastek.Salon.Service))
    end

    field :duration_min, :integer
    field :price_cents, :integer
    field :active, :boolean

    field :staff_ids, list_of(:id) do
      resolve(fn service, _, _ -> {:ok, Enum.map(service.staff, & &1.id)} end)
    end
  end

  object :staff_hour do
    field :weekday, :integer
    field :working, :boolean
    field :start_min, :integer
    field :end_min, :integer
  end

  object :staff do
    field :id, :id
    field :name, :string
    field :role, :string
    field :color, :string
    field :active, :boolean
    field :hours, list_of(:staff_hour)

    field :service_ids, list_of(:id) do
      resolve(fn staff, _, _ -> {:ok, Enum.map(staff.services, & &1.id)} end)
    end
  end

  object :client do
    field :id, :id
    field :first_name, :string
    field :last_name, :string
    field :email, :string
    field :phone, :string
    field :allergies, :string
    field :notes, :string

    field :created_at, :naive_datetime do
      resolve(fn parent, _, _ -> {:ok, parent.inserted_at} end)
    end

    # Batched: resolving these per row issued 2N+1 queries for the clients list.
    field :appt_count, :integer do
      resolve(&stat(&1, &2, &3, :appt_count))
    end

    field :total_spent_cents, :integer do
      resolve(&stat(&1, &2, &3, :total_spent_cents))
    end

    field :appointments, list_of(:appointment) do
      resolve(fn client, _, _ ->
        {:ok, Map.get(client, :appointments) |> loaded_or([])}
      end)
    end
  end

  object :appointment do
    field :id, :id
    field :booking_ref, :string
    field :date, :date
    field :start_min, :integer
    field :end_min, :integer
    field :status, :string
    field :price_cents, :integer
    field :notes, :string
    field :source, :string
    field :client, :client
    field :service, :service
    field :staff, :staff

    @desc "The venue this appointment belongs to — customers book across venues."
    field :venue, :venue_summary do
      resolve(fn appt, _, _ -> {:ok, Venues.get_venue(appt.venue_id)} end)
    end
  end

  object :sale_item do
    field :id, :id
    field :appointment_id, :id
    field :description, :string
    field :amount_cents, :integer
  end

  object :sale do
    field :id, :id
    field :subtotal_cents, :integer
    field :tip_cents, :integer
    field :total_cents, :integer
    field :payment_method, :string

    field :created_at, :naive_datetime do
      resolve(fn parent, _, _ -> {:ok, parent.inserted_at} end)
    end

    field :client, :client
    field :items, list_of(:sale_item)
  end

  object :review do
    field :id, :id
    field :client_name, :string
    field :rating, :integer
    field :comment, :string

    field :created_at, :naive_datetime do
      resolve(fn parent, _, _ -> {:ok, parent.inserted_at} end)
    end
  end

  @desc "One page of clients. `totalCount` is the size of the whole filtered set."
  object :client_page do
    field :items, non_null(list_of(non_null(:client)))
    field :total_count, non_null(:integer)
  end

  @desc "One page of sales."
  object :sale_page do
    field :items, non_null(list_of(non_null(:sale)))
    field :total_count, non_null(:integer)
  end

  @desc "One page of search results. `totalCount` is the whole filtered set."
  object :venue_page do
    field :items, non_null(list_of(non_null(:venue_summary)))
    field :total_count, non_null(:integer)
  end

  @desc """
  A venue photo's URLs, one per rendered size.

  Only `original` is guaranteed: the others appear once the variant worker has
  run, so a just-uploaded photo may briefly have none of them.
  """
  object :photo_urls do
    field :original, :string
    field :thumb, :string
    field :card, :string
    field :hero, :string
  end

  object :photo do
    field :id, :id
    field :alt, :string
    field :kind, :string
    field :sort, :integer
    field :status, :string
    field :width, :integer
    field :height, :integer

    field :urls, :photo_urls do
      resolve(fn photo, _, _ -> {:ok, Media.urls(photo)} end)
    end
  end

  @desc "A presigned upload: PUT the bytes to `url`, replaying every header."
  object :upload_ticket do
    field :photo, non_null(:photo)
    field :url, non_null(:string)
    field :headers, non_null(list_of(non_null(:http_header)))
  end

  object :http_header do
    field :name, non_null(:string)
    field :value, non_null(:string)
  end

  @desc "A city with listable venues, for the search filter."
  object :city_facet do
    field :city, :string
    field :venue_count, :integer
  end

  @desc "A treatment category offered somewhere on the marketplace."
  object :category_facet do
    field :name, :string
    field :service_count, :integer
  end

  @desc "A map coordinate."
  input_object :geo_point do
    field :lat, non_null(:float)
    field :lng, non_null(:float)
  end

  object :venue_hour do
    field :weekday, :integer
    field :open, :integer
    field :close, :integer
  end

  object :venue_stats do
    field :bookings, :integer
    field :professionals, :integer
    field :services, :integer
  end

  @desc "Identity of a venue, without its catalog — for lists and cross-links."
  object :venue_summary do
    field :id, :id
    field :slug, :string
    field :name, :string
    field :city, :string
    field :status, :string
    field :tagline, :string
    field :address, :string
    field :phone, :string

    # Batched: a results page would otherwise issue three queries per card.
    @desc "Mean review score, 0.0 when the venue has no reviews yet."
    field :rating, :float do
      resolve(&venue_card(&1, &2, &3, :rating))
    end

    field :review_count, :integer do
      resolve(&venue_card(&1, &2, &3, :review_count))
    end

    @desc "Cheapest active service, for \"from X MAD\" on a listing card."
    field :price_from_cents, :integer do
      resolve(&venue_card(&1, &2, &3, :price_from_cents))
    end

    @desc "Coordinates for the results map; null until the venue has a pin."
    field :lat, :float
    field :lng, :float

    @desc "Whether the venue serves women only — a marketplace search filter."
    field :women_only, :boolean do
      resolve(fn venue, _, _ -> {:ok, women_only?(venue)} end)
    end

    @desc "Why an admin turned this venue down, if they did. Null to outsiders."
    field :rejected_reason, :string do
      resolve(fn venue, args, res ->
        own_venue_field(venue, args, res, fn venue -> venue.rejected_reason end)
      end)
    end

    @desc "Progress through the setup wizard. Null to outsiders."
    field :onboarding, :onboarding_state do
      resolve(fn venue, args, res -> own_venue_field(venue, args, res, &onboarding_state/1) end)
    end

    @desc """
    The settings blob, as JSON. Written through `updateVenueSettings`.

    Null to outsiders: a venue's notice period, cancellation window and whether
    it vets its bookings are its own business, not a shopper's.
    """
    field :settings_json, :json do
      resolve(fn venue, args, res ->
        own_venue_field(venue, args, res, fn venue -> venue.settings || %{} end)
      end)
    end

    @desc """
    Kilometres from the point given as `near`.

    Null on any search that did not supply one — it is a property of the query,
    not of the venue.
    """
    field :distance_km, :float

    @desc "Card-sized URL of the venue's cover photo, or null when it has none."
    field :cover_url, :string do
      resolve(&venue_cover/3)
    end

    @desc "The venue's photos, cover first."
    field :photos, list_of(:photo) do
      resolve(&venue_photos/3)
    end
  end

  @desc "Public marketplace view of one venue."
  object :venue do
    field :id, :id
    field :slug, :string
    field :city, :string
    field :status, :string
    field :settings, :settings

    @desc "Coordinates for the map; null until the venue has been geocoded."
    field :lat, :float
    field :lng, :float

    @desc """
    Facts a shopper checks before booking (parking, card accepted, wheelchair
    access…). Venue-declared, so the list is open rather than an enum.
    """
    field :amenities, list_of(:string)

    @desc "Whether the venue serves women only."
    field :women_only, :boolean

    @desc "Gallery photos, cover first."
    field :photos, list_of(:photo)
    field :categories, list_of(:category)
    field :services, list_of(:service)
    field :staff, list_of(:staff)
    field :reviews, list_of(:review)
    field :rating, :float
    field :hours, list_of(:venue_hour)
    field :stats, :venue_stats
  end

  @desc "A venue the signed-in user can administer, with their role in it."
  object :venue_membership do
    field :id, :id
    field :role, :string
    field :venue, :venue_summary

    @desc "The person. Absent on a membership loaded without its user."
    field :user, :team_member do
      resolve(fn membership, _, _ -> {:ok, loaded_or(membership.user, nil)} end)
    end

    @desc "Calendar column this member owns, when they take appointments."
    field :staff_id, :id
  end

  @desc """
  A colleague, as their teammates see them.

  Deliberately not the full `:user` type: a manager listing the team has no
  business reading another member's platform role or venue list.
  """
  object :team_member do
    field :id, :id
    field :first_name, :string
    field :last_name, :string
    field :email, :string
    field :phone, :string
  end

  @desc "A role held open for someone who has not joined yet."
  object :invitation do
    field :id, :id
    field :role, :string
    field :phone, :string
    field :email, :string
    field :expires_at, :naive_datetime
    field :inserted_at, :naive_datetime
  end

  @desc """
  A freshly created invitation.

  `url` is returned once and never again — it contains the raw token, which is
  not recoverable from storage. Showing it lets an owner hand the link over in
  person when delivery fails or the invitee is standing right there.
  """
  object :invitation_created do
    field :invitation, non_null(:invitation)
    field :url, non_null(:string)

    @desc """
    Whether the message actually went out.

    False is not a failure — the invitation works and `url` can be shared by
    hand. It exists so the UI does not claim "sent" when nothing was.
    """
    field :delivered, non_null(:boolean)
  end

  @desc "What an invitation link is offering, shown before asking anyone to sign in."
  object :invitation_preview do
    field :role, :string
    field :venue_name, :string
    field :venue_slug, :string
    field :expires_at, :naive_datetime
  end

  @desc "A period the venue is shut. Null times mean the whole day."
  object :closure do
    field :id, :id
    field :date, :date

    @desc "Last day of a span; null for a single day."
    field :end_date, :date

    field :start_min, :integer
    field :end_min, :integer
    field :reason, :string
  end

  @desc "One day in a weekly grid. `endMin` may exceed 1440 for a shift past midnight."
  object :hour_day do
    field :weekday, non_null(:integer)
    field :working, non_null(:boolean)
    field :start_min, non_null(:integer)
    field :end_min, non_null(:integer)
  end

  @desc "A named weekly grid — `default`, `ramadan`, or whatever the venue calls it."
  object :hour_template do
    field :id, :id
    field :name, :string
    field :active, :boolean

    field :days, list_of(:hour_day) do
      resolve(fn template, _, _ ->
        {:ok, template |> Venues.Schedule.week_list() |> Enum.map(&atomize_day/1)}
      end)
    end
  end

  input_object :hour_day_input do
    field :weekday, non_null(:integer)
    field :working, non_null(:boolean)
    field :start_min, non_null(:integer)
    field :end_min, non_null(:integer)
  end

  @desc """
  Options that live in the settings blob.

  Every field is optional: sending one must not blank the rest.
  """
  input_object :venue_settings_input do
    field :women_only, :boolean
    field :amenities, list_of(non_null(:string))
    field :slot_step_min, :integer
    field :booking_lead_min, :integer
    field :booking_horizon_days, :integer
    field :cancellation_window_hours, :integer
    field :instant_confirmation, :boolean
    field :locale, :string
  end

  @desc "A starter catalog offered during onboarding."
  object :service_catalog do
    field :catalog, :string
    field :service_count, :integer
  end

  @desc "A starter service. `name` is resolved for the requested locale."
  object :service_template do
    field :id, :id
    field :catalog, :string
    field :category, :string
    field :duration_min, :integer
    field :price_hint_cents, :integer

    field :name, :string do
      arg(:locale, :string, default_value: "fr")

      resolve(fn template, args, _ ->
        {:ok, Blastek.Venues.ServiceTemplate.name(template, args.locale)}
      end)
    end
  end

  @desc "How far through the setup wizard a venue is."
  object :onboarding_state do
    field :current_step, :string
    field :completed, list_of(:string)
    field :submitted, non_null(:boolean)
    field :complete, non_null(:boolean)

    @desc "Saved answers, keyed by step. Shape follows the wizard, not the database."
    field :data, :json
  end

  @desc "One recorded change to who can do what."
  object :audit_entry do
    field :id, :id

    @desc ~s|Dotted verb, e.g. "member.role_changed".|
    field :action, :string

    field :subject_type, :string
    field :subject_id, :integer
    field :inserted_at, :naive_datetime

    @desc "Who did it. Null when the account has since been deleted."
    field :actor, :team_member do
      # Batched: a fifty-row log would otherwise be fifty user lookups, and the
      # same handful of people appear over and over.
      resolve(fn
        %{actor_user_id: nil}, _, _ ->
          {:ok, nil}

        entry, _, _ ->
          batch({__MODULE__, :batch_users, nil}, entry.actor_user_id, fn users ->
            {:ok, Map.get(users, entry.actor_user_id)}
          end)
      end)
    end

    @desc "Before-and-after detail, as JSON. Shape depends on `action`."
    field :metadata, :json do
      resolve(fn entry, _, _ -> {:ok, entry.metadata} end)
    end
  end

  @desc "Arbitrary JSON. Used where the shape depends on a sibling field."
  scalar :json, name: "Json" do
    serialize(& &1)
    parse(fn %Absinthe.Blueprint.Input.String{value: value} -> Jason.decode(value) end)
  end

  object :slot do
    field :start_min, :integer
    field :staff_id, :id
  end

  object :availability_result do
    field :total_duration, :integer
    field :slots, list_of(:slot)
  end

  object :booking_result do
    field :booking_ref, :string
    field :date, :date
    field :start_min, :integer
    field :end_min, :integer
    field :staff_name, :string
    field :appointments, list_of(:appointment)
  end

  object :appt_stats do
    field :completed, :integer
    field :no_shows, :integer
    field :cancelled, :integer
    field :online, :integer
    field :total, :integer
  end

  object :day_revenue do
    field :day, :date
    field :revenue_cents, :integer
  end

  object :top_entry do
    field :name, :string
    field :color, :string
    field :count, :integer
    field :revenue_cents, :integer
  end

  object :report_summary do
    field :days, :integer
    field :revenue_cents, :integer
    field :tips_cents, :integer
    field :sales_count, :integer
    field :appointments, :appt_stats
    field :new_clients, :integer
    field :revenue_by_day, list_of(:day_revenue)
    field :top_services, list_of(:top_entry)
    field :top_staff, list_of(:top_entry)
  end

  object :user do
    field :id, :id
    field :email, :string
    field :role, :string
    field :first_name, :string
    field :last_name, :string
    field :phone, :string

    @desc "Whether the phone number has been proven by a one-time code."
    field :phone_verified, :boolean do
      resolve(fn user, _, _ -> {:ok, user.phone_verified_at != nil} end)
    end

    @desc "False until an account created by phone has been given a name."
    field :profile_complete, :boolean do
      resolve(fn user, _, _ -> {:ok, Accounts.profile_complete?(user)} end)
    end

    @desc "Whether a password is set — phone-first accounts start without one."
    field :has_password, :boolean do
      resolve(fn user, _, _ -> {:ok, user.password_hash != nil} end)
    end

    @desc "Venues this account administers (empty for pure customers)."
    field :venues, list_of(:venue_membership) do
      resolve(fn user, _, _ -> {:ok, Venues.list_memberships(user.id)} end)
    end

    @desc """
    Which optional messages this account accepts.

    Transactional messages — booking confirmations, one-time codes — are not
    listed because they cannot be turned off.
    """
    field :notification_prefs, :notification_prefs do
      resolve(fn user, _, _ -> {:ok, Notifications.prefs(user)} end)
    end

    @desc """
    The language this account reads, or null if they have never chosen.

    Null rather than "fr" so the client can tell "has not chosen" from "chose
    French" — only the first should let `Accept-Language` decide.
    """
    field :locale, :string
  end

  @desc "Optional message categories. Transactional messages always send."
  object :notification_prefs do
    field :reminders, :boolean do
      resolve(fn prefs, _, _ -> {:ok, Map.get(prefs, "reminders", true)} end)
    end

    field :marketing, :boolean do
      resolve(fn prefs, _, _ -> {:ok, Map.get(prefs, "marketing", false)} end)
    end
  end

  @desc "One attempt to reach one person — the send log (F0.12)."
  object :notification do
    field :id, :id
    field :to, :string
    field :template, :string
    field :channel, :string
    field :locale, :string
    field :body, :string

    @desc "queued | sent | delivered | failed | skipped"
    field :status, :string

    @desc "Why it failed, or why it was skipped."
    field :error, :string

    field :provider, :string
    field :attempts, :integer
    field :sent_at, :naive_datetime
    field :delivered_at, :naive_datetime
    field :inserted_at, :naive_datetime
    field :venue_id, :id
    field :appointment_id, :id
  end

  object :notification_page do
    field :items, list_of(:notification)
    field :total_count, :integer
  end

  object :auth_payload do
    field :token, :string
    field :user, :user

    @desc "Exchange for a new pair via `refreshSession` when `token` expires."
    field :refresh_token, :string

    field :expires_at, :naive_datetime

    @desc """
    False for an account created by phone that has not been named yet — the
    client should ask for a name before letting them book.
    """
    field :profile_complete, :boolean
  end

  @desc "A code was sent."
  object :otp_request do
    @desc """
    The destination, partly hidden: `06 •• •• 56 78`.

    Named for what it is. A field called `phone` returning a masked string
    invites a client to store or resend it.
    """
    field :masked_phone, :string

    field :expires_at, :naive_datetime

    @desc "Seconds before another code may be requested."
    field :resend_after, :integer
  end

  @desc "One signed-in device."
  object :session do
    field :id, :id

    @desc "Human-readable device label derived from the User-Agent."
    field :device, :string do
      resolve(fn session, _, _ -> {:ok, Blastek.Accounts.Sessions.describe(session)} end)
    end

    field :ip, :string
    field :last_used_at, :naive_datetime
    field :expires_at, :naive_datetime
    field :inserted_at, :naive_datetime

    @desc "Whether this is the session making the request — do not offer to revoke it."
    field :current, :boolean do
      resolve(fn session, _, %{context: ctx} ->
        {:ok, ctx[:current_session] != nil and ctx.current_session.id == session.id}
      end)
    end
  end

  ## ---------- inputs ----------

  input_object :client_input do
    field :first_name, :string
    field :last_name, :string
    field :email, :string
    field :phone, :string
    field :allergies, :string
    field :notes, :string
  end

  input_object :staff_hour_input do
    field :weekday, non_null(:integer)
    field :working, non_null(:boolean)
    field :start_min, non_null(:integer)
    field :end_min, non_null(:integer)
  end

  input_object :venue_input do
    field :name, :string
    field :tagline, :string
    field :address, :string
    field :city, :string
    field :phone, :string
  end

  ## ---------- queries ----------

  query do
    field :me, :user do
      resolve(fn _, %{context: ctx} -> {:ok, ctx[:current_user]} end)
    end

    @desc "Venues the signed-in user administers."
    field :my_venues, list_of(:venue_membership) do
      middleware(RequireAuth)
      resolve(fn _, %{context: ctx} -> {:ok, Venues.list_memberships(ctx.current_user.id)} end)
    end

    @desc "Devices currently signed in to this account, most recently used first."
    field :my_sessions, list_of(:session) do
      middleware(RequireAuth)

      resolve(fn _, %{context: ctx} ->
        {:ok, Blastek.Accounts.Sessions.list_for_user(ctx.current_user.id)}
      end)
    end

    @desc "The venue the current dashboard session is acting on."
    field :current_venue, :venue_summary do
      middleware(RequireMember, "staff")
      resolve(fn _, %{context: ctx} -> {:ok, ctx.current_venue} end)
    end

    @desc "Public venue page, addressed by slug."
    field :venue, :venue do
      arg(:slug, non_null(:string))

      resolve(fn %{slug: slug}, _ ->
        with {:ok, venue} <- Venues.get_public_by_slug(slug) do
          {:ok, Salon.venue_view(venue)}
        end
      end)
    end

    @desc """
    Active venues on the marketplace, optionally filtered by a search term.

    The unpaginated convenience form, for the homepage's featured strip. Use
    `searchVenues` for anything a shopper drives.
    """
    field :venues, list_of(:venue_summary) do
      @desc "Free text matched against venue identity and the treatments offered."
      arg(:q, :string)
      arg(:limit, :integer, default_value: 24)

      resolve(fn args, _ ->
        page = Discovery.search(q: args[:q], limit: args[:limit])
        {:ok, page.items}
      end)
    end

    @desc """
    Marketplace search: full text, filters, sorting and paging.

    `q` matches a venue's name, city, address and the treatments it offers, with
    words ANDed — "fade rabat" finds the Rabat barber who does fades.
    """
    field :search_venues, non_null(:venue_page) do
      arg(:q, :string)
      arg(:city, :string)
      arg(:category, :string)

      @desc "Restrict to venues that serve women only. False and null both mean \"no preference\"."
      arg(:women_only, :boolean)

      @desc "Where the shopper is, enabling `distanceKm` and `sort: \"distance\"`."
      arg(:near, :geo_point)

      @desc "Only venues within this many kilometres of `near`."
      arg(:within_km, :float)

      @desc "One of: relevance (default), distance, rating, price, name."
      arg(:sort, :string)

      arg(:limit, :integer, default_value: 24)
      arg(:offset, :integer, default_value: 0)

      resolve(fn args, _ ->
        {:ok,
         Discovery.search(
           q: args[:q],
           city: args[:city],
           category: args[:category],
           women_only: args[:women_only],
           near: near_point(args[:near]),
           within_km: args[:within_km],
           sort: args[:sort],
           limit: args[:limit],
           offset: args[:offset]
         )}
      end)
    end

    @desc "Cities that currently have listable venues, for the search filter."
    field :venue_cities, list_of(:city_facet) do
      resolve(fn _, _ -> {:ok, Discovery.cities()} end)
    end

    @desc "Treatment categories offered somewhere on the marketplace."
    field :venue_categories, list_of(:category_facet) do
      resolve(fn _, _ -> {:ok, Discovery.categories()} end)
    end

    @desc """
    Every photo of the active venue, including ones still processing.

    The dashboard needs the `pending` and `failed` rows the public gallery hides,
    or an upload that went wrong would simply vanish with no way to retry it.
    """
    field :venue_photos, list_of(:photo) do
      middleware(RequireMember, "manager")
      resolve(fn _, %{context: ctx} -> {:ok, Media.list_all_photos(ctx.venue_id)} end)
    end

    ## --- dashboard (venue-scoped) ---

    field :settings, :settings do
      middleware(RequireMember, "staff")

      resolve(fn _, %{context: ctx} ->
        v = ctx.current_venue

        {:ok,
         %{
           business_name: v.name,
           business_tagline: v.tagline,
           business_address: v.address,
           business_phone: v.phone
         }}
      end)
    end

    field :categories, list_of(:category) do
      middleware(RequireMember, "staff")
      resolve(fn _, %{context: ctx} -> {:ok, Salon.list_categories(ctx.venue_id)} end)
    end

    field :services, list_of(:service) do
      middleware(RequireMember, "staff")
      resolve(fn _, %{context: ctx} -> {:ok, Salon.list_services(ctx.venue_id)} end)
    end

    field :staff, list_of(:staff) do
      middleware(RequireMember, "staff")
      resolve(fn _, %{context: ctx} -> {:ok, Salon.list_staff(ctx.venue_id)} end)
    end

    field :appointments, list_of(:appointment) do
      arg(:from, non_null(:date))
      arg(:to, non_null(:date))
      middleware(RequireMember, "staff")

      resolve(fn %{from: f, to: t}, %{context: ctx} ->
        # The calendar shows a day or a week; a range is the natural bound here,
        # so cap the span rather than paginate rows.
        cond do
          Date.compare(f, t) == :gt ->
            {:error, "`from` must not be after `to`."}

          Date.diff(t, f) > @max_calendar_days ->
            {:error, "Date range is too wide (max 92 days)."}

          true ->
            {:ok, Salon.list_appointments(ctx.venue_id, f, t, own_staff_scope(ctx))}
        end
      end)
    end

    @desc "Clients of the active venue, paginated."
    field :clients, non_null(:client_page) do
      arg(:q, :string)
      arg(:limit, :integer, default_value: 50)
      arg(:offset, :integer, default_value: 0)

      # Staff may reach this, narrowed to the people they have served — the
      # "limited CRM" of F0.3. The venue's full client list stays a
      # receptionist-and-above thing.
      middleware(RequireMember, "staff")

      resolve(fn args, %{context: ctx} ->
        scope = own_client_scope(ctx)
        page = page_args(args) ++ scope

        {:ok,
         %{
           items: Salon.list_clients(ctx.venue_id, args[:q], page),
           total_count: Salon.count_clients(ctx.venue_id, args[:q], scope)
         }}
      end)
    end

    field :client, :client do
      arg(:id, non_null(:id))
      middleware(RequireMember, "staff")

      resolve(fn %{id: id}, %{context: ctx} ->
        # A staff member guessing a colleague's client id gets the same "Not
        # found." as a genuinely missing one.
        found(fn -> {:ok, Salon.get_client!(ctx.venue_id, id, own_client_scope(ctx))} end)
      end)
    end

    @desc "Sales of the active venue since a date, paginated."
    field :sales, non_null(:sale_page) do
      arg(:from, non_null(:date))
      arg(:limit, :integer, default_value: 50)
      arg(:offset, :integer, default_value: 0)
      middleware(RequireMember, "manager")

      resolve(fn args, %{context: ctx} ->
        page = page_args(args)

        {:ok,
         %{
           items: Salon.list_sales(ctx.venue_id, args.from, page),
           total_count: Salon.count_sales(ctx.venue_id, args.from)
         }}
      end)
    end

    field :report_summary, :report_summary do
      arg(:days, :integer, default_value: 30)
      middleware(RequireMember, "manager")
      resolve(fn %{days: d}, %{context: ctx} -> {:ok, Salon.report_summary(ctx.venue_id, d)} end)
    end

    field :venue_members, list_of(:venue_membership) do
      middleware(RequireMember, "manager")
      resolve(fn _, %{context: ctx} -> {:ok, Venues.list_members(ctx.venue_id)} end)
    end

    @desc "Invitations sent but not yet accepted."
    field :pending_invitations, list_of(:invitation) do
      middleware(RequireMember, "manager")
      resolve(fn _, %{context: ctx} -> {:ok, Invitations.list_pending(ctx.venue_id)} end)
    end

    @desc """
    What an invitation link offers, without redeeming it.

    Public: the holder of the link has not signed in yet, and asking them to
    before telling them what they are joining is how people accept things
    blindly. The token is the secret; the venue's name is not.
    """
    field :invitation, :invitation_preview do
      arg(:token, non_null(:string))

      resolve(fn %{token: token}, _ ->
        case Invitations.preview(token) do
          {:ok, %{invitation: invitation, venue: venue}} ->
            {:ok,
             %{
               role: invitation.role,
               venue_name: venue && venue.name,
               venue_slug: venue && venue.slug,
               expires_at: invitation.expires_at
             }}

          other ->
            format_errors(other)
        end
      end)
    end

    @desc "Upcoming closures for the active venue."
    field :venue_closures, list_of(:closure) do
      arg(:from, :date)
      arg(:to, :date)
      middleware(RequireMember, "staff")

      resolve(fn args, %{context: ctx} ->
        {:ok,
         Venues.Schedule.list_closures(ctx.venue_id,
           from: args[:from] || Date.utc_today(),
           to: args[:to]
         )}
      end)
    end

    @desc "The venue's saved weekly grids, the active one first."
    field :venue_hour_templates, list_of(:hour_template) do
      middleware(RequireMember, "manager")
      resolve(fn _, %{context: ctx} -> {:ok, Venues.Schedule.list_templates(ctx.venue_id)} end)
    end

    @desc """
    The hours the venue actually keeps this week, under whichever template is
    in use — the same seven rows the marketplace advertises.

    A venue carried over from before templates existed has no saved grid at
    all, and the dashboard still has to be able to show it its own opening
    hours rather than an empty panel.
    """
    field :venue_week, list_of(:venue_hour) do
      middleware(RequireMember, "manager")
      resolve(fn _, %{context: ctx} -> {:ok, Salon.venue_week(ctx.venue_id)} end)
    end

    @desc """
    Appointments a proposed closure would strand.

    A dry run: nothing is created and nothing is cancelled. F0.4 is explicit
    that bookings inside a new closure are shown to the owner to act on, never
    silently dropped — a salon closing for a funeral still has to telephone the
    four people booked that afternoon.
    """
    field :closure_conflicts, list_of(:appointment) do
      arg(:date, non_null(:date))
      arg(:end_date, :date)
      arg(:start_min, :integer)
      arg(:end_min, :integer)

      middleware(RequireMember, "manager")

      resolve(fn args, %{context: ctx} ->
        {:ok,
         Salon.appointments_in_window(
           ctx.venue_id,
           args.date,
           args[:end_date],
           args[:start_min],
           args[:end_min]
         )}
      end)
    end

    @desc "Starter catalogs offered during onboarding."
    field :service_catalogs, list_of(:service_catalog) do
      resolve(fn _, _ -> {:ok, Venues.Onboarding.catalogs()} end)
    end

    @desc "The services in one starter catalog."
    field :service_templates, list_of(:service_template) do
      arg(:catalog, non_null(:string))
      resolve(fn %{catalog: catalog}, _ -> {:ok, Venues.Onboarding.templates_for(catalog)} end)
    end

    @desc "Venues waiting for a decision, oldest first."
    field :venue_review_queue, list_of(:venue_summary) do
      middleware(RequireAdmin)
      resolve(fn _, _ -> {:ok, Venues.Onboarding.review_queue()} end)
    end

    @desc """
    Venues that look like the same business as this one.

    A hint for the reviewer, not a verdict: two salons in one city really can
    share a name, and a franchise really does reuse a phone number.
    """
    field :venue_duplicates, list_of(:venue_summary) do
      arg(:id, non_null(:id))
      middleware(RequireAdmin)

      resolve(fn %{id: id}, _ ->
        case Venues.get_venue(to_int(id)) do
          nil -> {:error, "Unknown venue."}
          venue -> {:ok, Venues.Onboarding.possible_duplicates(venue)}
        end
      end)
    end

    @desc """
    The notification send log, newest first (E6-T2 / F0.12).

    Admin-only, because it holds the body of every message sent to every
    customer — phone numbers, names, and the times they turn up somewhere.
    A venue's own view of what it sent to whom belongs to a later epic with a
    narrower query; there is no safe way to hand this one out per-venue while
    the filters are caller-supplied.
    """
    field :notification_log, non_null(:notification_page) do
      arg(:venue_id, :id)
      arg(:user_id, :id)

      @desc "queued | sent | delivered | failed | skipped"
      arg(:status, :string)

      arg(:template, :string)
      arg(:limit, :integer, default_value: 50)
      arg(:offset, :integer, default_value: 0)

      middleware(RequireAdmin)

      resolve(fn args, _ ->
        opts = [
          venue_id: int_or_nil(args[:venue_id]),
          user_id: int_or_nil(args[:user_id]),
          status: args[:status],
          template: args[:template],
          limit: args[:limit],
          offset: args[:offset]
        ]

        {:ok, %{items: Notifications.list_log(opts), total_count: Notifications.count_log(opts)}}
      end)
    end

    @desc "Recent changes to who can do what here."
    field :audit_log, list_of(:audit_entry) do
      arg(:limit, :integer, default_value: 50)
      middleware(RequireMember, "owner")

      resolve(fn args, %{context: ctx} ->
        {:ok, Audit.list_for_venue(ctx.venue_id, limit: args[:limit])}
      end)
    end

    ## --- customer ---

    @desc "The signed-in customer's bookings across every venue."
    field :my_appointments, list_of(:appointment) do
      middleware(RequireAuth)

      resolve(fn _, %{context: ctx} ->
        {:ok, Salon.list_my_appointments(Accounts.client_ids(ctx.current_user))}
      end)
    end

    @desc "Bookable start times at a venue for a set of services."
    field :availability, :availability_result do
      arg(:venue_slug, non_null(:string))
      arg(:service_ids, non_null(list_of(non_null(:id))))
      arg(:staff_id, :string, default_value: "any")
      arg(:date, non_null(:date))

      resolve(fn args, _ ->
        with {:ok, venue} <- Venues.get_public_by_slug(args.venue_slug) do
          Salon.availability(venue.id, ids(args.service_ids), args.staff_id, args.date)
        end
      end)
    end

    ## --- platform admin ---

    field :admin_venues, list_of(:venue_summary) do
      middleware(RequireAdmin)
      resolve(fn _, _ -> {:ok, Venues.list_venues()} end)
    end
  end

  ## ---------- mutations ----------

  mutation do
    field :create_appointment, :appointment do
      arg(:client_id, :id)
      arg(:client, :client_input)
      arg(:staff_id, non_null(:id))
      arg(:service_id, non_null(:id))
      arg(:date, non_null(:date))
      arg(:start_min, non_null(:integer))
      arg(:notes, :string)

      middleware(RequireMember, "receptionist")

      resolve(fn args, %{context: ctx} ->
        found(fn ->
          args
          |> Map.update(:client_id, nil, &int_or_nil/1)
          |> Map.update!(:staff_id, &to_int/1)
          |> Map.update!(:service_id, &to_int/1)
          |> then(&Salon.create_appointment(ctx.venue_id, &1))
          |> broadcast()
          |> format_errors()
        end)
      end)
    end

    field :update_appointment, :appointment do
      arg(:id, non_null(:id))
      arg(:status, :string)
      arg(:date, :date)
      arg(:start_min, :integer)
      arg(:staff_id, :id)
      arg(:price_cents, :integer)
      arg(:notes, :string)

      middleware(RequireMember, "receptionist")

      resolve(fn args, %{context: ctx} ->
        found(fn ->
          {id, rest} = Map.pop(args, :id)
          rest = Map.update(rest, :staff_id, nil, &int_or_nil/1)
          Salon.update_appointment(ctx.venue_id, id, rest) |> broadcast() |> format_errors()
        end)
      end)
    end

    field :create_client, :client do
      arg(:input, non_null(:client_input))
      middleware(RequireMember, "receptionist")

      resolve(fn %{input: input}, %{context: ctx} ->
        Salon.create_client(ctx.venue_id, input) |> format_errors()
      end)
    end

    field :update_client, :client do
      arg(:id, non_null(:id))
      arg(:input, non_null(:client_input))

      middleware(RequireMember, "receptionist")

      resolve(fn %{id: id, input: input}, %{context: ctx} ->
        found(fn -> Salon.update_client(ctx.venue_id, id, input) |> format_errors() end)
      end)
    end

    field :create_category, :category do
      arg(:name, non_null(:string))

      @desc "Per-locale names, `{\"ar\": {\"name\": \"…\"}}`. French writes the base column."
      arg(:translations, :json)

      middleware(RequireMember, "manager")

      resolve(fn args, %{context: ctx} ->
        Salon.create_category(
          ctx.venue_id,
          %{name: args.name, translations: args[:translations] || %{}, sort: 99}
        )
        |> format_errors()
      end)
    end

    field :update_category, :category do
      arg(:id, non_null(:id))
      arg(:name, :string)
      arg(:translations, :json)

      middleware(RequireMember, "manager")

      resolve(fn args, %{context: ctx} ->
        {id, attrs} = Map.pop(args, :id)
        found(fn -> Salon.update_category(ctx.venue_id, id, attrs) |> format_errors() end)
      end)
    end

    field :create_service, :service do
      arg(:category_id, non_null(:id))
      arg(:name, non_null(:string))
      arg(:description, :string)

      @desc "Per-locale name and description. French writes the base columns."
      arg(:translations, :json)

      arg(:duration_min, non_null(:integer))
      arg(:price_cents, non_null(:integer))
      arg(:staff_ids, list_of(non_null(:id)))

      middleware(RequireMember, "manager")

      resolve(fn args, %{context: ctx} ->
        {staff_ids, attrs} = Map.pop(args, :staff_ids)

        Salon.create_service(ctx.venue_id, attrs, staff_ids && ids(staff_ids))
        |> format_errors()
      end)
    end

    field :update_service, :service do
      arg(:id, non_null(:id))
      arg(:category_id, :id)
      arg(:name, :string)
      arg(:description, :string)
      arg(:translations, :json)
      arg(:duration_min, :integer)
      arg(:price_cents, :integer)
      arg(:active, :boolean)
      arg(:staff_ids, list_of(non_null(:id)))

      middleware(RequireMember, "manager")

      resolve(fn args, %{context: ctx} ->
        {id, rest} = Map.pop(args, :id)
        {staff_ids, attrs} = Map.pop(rest, :staff_ids)

        found(fn ->
          Salon.update_service(ctx.venue_id, id, attrs, staff_ids && ids(staff_ids))
          |> format_errors()
        end)
      end)
    end

    field :create_staff, :staff do
      arg(:name, non_null(:string))
      arg(:role, :string)
      arg(:color, :string)
      arg(:active, :boolean)
      arg(:hours, list_of(non_null(:staff_hour_input)))
      arg(:service_ids, list_of(non_null(:id)))

      middleware(RequireMember, "manager")

      resolve(fn args, %{context: ctx} ->
        {hours, rest} = Map.pop(args, :hours)
        {service_ids, attrs} = Map.pop(rest, :service_ids)

        Salon.create_staff(ctx.venue_id, attrs, hours, service_ids && ids(service_ids))
        |> format_errors()
      end)
    end

    field :update_staff, :staff do
      arg(:id, non_null(:id))
      arg(:name, :string)
      arg(:role, :string)
      arg(:color, :string)
      arg(:active, :boolean)
      arg(:hours, list_of(non_null(:staff_hour_input)))
      arg(:service_ids, list_of(non_null(:id)))

      middleware(RequireMember, "manager")

      resolve(fn args, %{context: ctx} ->
        {id, rest} = Map.pop(args, :id)
        {hours, rest} = Map.pop(rest, :hours)
        {service_ids, attrs} = Map.pop(rest, :service_ids)

        found(fn ->
          Salon.update_staff(ctx.venue_id, id, attrs, hours, service_ids && ids(service_ids))
          |> format_errors()
        end)
      end)
    end

    field :update_venue, :venue_summary do
      arg(:input, non_null(:venue_input))
      middleware(RequireMember, "owner")

      resolve(fn %{input: input}, %{context: ctx} ->
        Venues.update_venue(ctx.current_venue, input) |> format_errors()
      end)
    end

    @desc """
    Updates the options in the settings blob.

    Only the fields sent are touched, and each is range-checked — the column is
    schemaless, so the discipline has to live here.
    """
    field :update_venue_settings, :venue_summary do
      arg(:input, non_null(:venue_settings_input))
      middleware(RequireMember, "manager")

      resolve(fn %{input: input}, %{context: ctx} ->
        Venues.update_settings(ctx.current_venue, input) |> format_errors()
      end)
    end

    @desc "Closes the venue for a day, a span of days, or a window within one."
    field :create_closure, :closure do
      arg(:date, non_null(:date))
      arg(:end_date, :date)

      @desc "Both or neither. Omit for a whole-day closure."
      arg(:start_min, :integer)
      arg(:end_min, :integer)

      arg(:reason, :string)

      middleware(RequireMember, "manager")

      resolve(fn args, %{context: ctx} ->
        Venues.Schedule.create_closure(ctx.venue_id, args) |> format_errors()
      end)
    end

    field :delete_closure, :closure do
      arg(:id, non_null(:id))
      middleware(RequireMember, "manager")

      resolve(fn %{id: id}, %{context: ctx} ->
        Venues.Schedule.delete_closure(ctx.venue_id, to_int(id)) |> format_errors()
      end)
    end

    @desc """
    Saves a weekly grid under a name, creating or replacing it.

    Days may be sent partially; the rest of the week keeps its current shape
    rather than closing.
    """
    field :save_hour_template, :hour_template do
      arg(:name, non_null(:string))
      arg(:days, non_null(list_of(non_null(:hour_day_input))))

      middleware(RequireMember, "manager")

      resolve(fn %{name: name, days: days}, %{context: ctx} ->
        Venues.Schedule.upsert_template(ctx.venue_id, name, days) |> format_errors()
      end)
    end

    @desc "Switches the venue to a saved grid — the one-tap seasonal change."
    field :set_hour_template, :hour_template do
      arg(:name, non_null(:string))
      middleware(RequireMember, "manager")

      resolve(fn %{name: name}, %{context: ctx} ->
        Venues.Schedule.activate_template(ctx.venue_id, name) |> format_errors()
      end)
    end

    @desc "Creates real services from chosen starter templates."
    field :apply_service_templates, list_of(:service) do
      arg(:template_ids, non_null(list_of(non_null(:id))))
      arg(:locale, :string, default_value: "fr")

      middleware(RequireMember, "manager")

      resolve(fn args, %{context: ctx} ->
        case Venues.Onboarding.apply_templates(
               ctx.current_venue,
               ids(args.template_ids),
               args.locale
             ) do
          {:ok, services} -> {:ok, Repo.preload(services, :staff)}
          other -> format_errors(other)
        end
      end)
    end

    ## --- onboarding (F0.5) ---

    @desc """
    Creates a venue owned by the signed-in account.

    Starts `pending`: the dashboard works immediately so an owner can build
    their catalog and invite their team, while the public page stays hidden
    until an admin approves.
    """
    field :create_venue, :venue_summary do
      arg(:name, non_null(:string))
      arg(:city, :string)
      arg(:address, :string)
      arg(:phone, :string)

      middleware(RequireAuth)

      resolve(fn args, %{context: %{current_user: user}} ->
        attrs = args |> Map.take([:name, :city, :address, :phone]) |> Map.put(:status, "pending")

        case Venues.create_venue_with_owner(attrs, user.id) do
          {:ok, venue} -> {:ok, venue}
          other -> format_errors(other)
        end
      end)
    end

    @desc "Saves one step of the setup wizard so a dropped connection resumes where it left off."
    field :update_onboarding, :venue_summary do
      arg(:step, non_null(:string))
      arg(:data, :json)

      middleware(RequireMember, "manager")

      resolve(fn args, %{context: ctx} ->
        Venues.Onboarding.update_step(ctx.current_venue, args.step, args[:data] || %{})
        |> format_errors()
      end)
    end

    @desc "Hands the venue to the admin queue for review."
    field :submit_venue, :venue_summary do
      middleware(RequireMember, "owner")

      resolve(fn _, %{context: ctx} ->
        Venues.Onboarding.submit(ctx.current_venue, ctx.current_user) |> format_errors()
      end)
    end

    @desc "Puts a venue live."
    field :approve_venue, :venue_summary do
      arg(:id, non_null(:id))
      middleware(RequireAdmin)

      resolve(fn %{id: id}, %{context: ctx} ->
        Venues.Onboarding.approve(to_int(id), ctx.current_user) |> format_errors()
      end)
    end

    @desc "Turns a venue down. The reason is required — the owner needs to know what to fix."
    field :reject_venue, :venue_summary do
      arg(:id, non_null(:id))
      arg(:reason, non_null(:string))
      middleware(RequireAdmin)

      resolve(fn args, %{context: ctx} ->
        Venues.Onboarding.reject(to_int(args.id), args.reason, ctx.current_user)
        |> format_errors()
      end)
    end

    @desc """
    Sets whether the venue serves women only — a marketplace search filter.

    Its own mutation rather than a field on `updateVenue`: it lives in the
    settings JSONB, and E5 is what gives that a typed, validated write path.
    """
    field :set_venue_women_only, :venue_summary do
      arg(:value, non_null(:boolean))
      middleware(RequireMember, "manager")

      resolve(fn %{value: value}, %{context: ctx} ->
        Venues.set_women_only(ctx.current_venue, value) |> format_errors()
      end)
    end

    @desc """
    Places the venue's map pin by hand.

    Always wins over `geocodeVenue`: the owner knows which door customers use.
    """
    field :set_venue_location, :venue_summary do
      arg(:lat, non_null(:float))
      arg(:lng, non_null(:float))
      middleware(RequireMember, "manager")

      resolve(fn %{lat: lat, lng: lng}, %{context: ctx} ->
        Venues.set_location(ctx.current_venue, lat, lng) |> format_errors()
      end)
    end

    @desc """
    Guesses the venue's coordinates from its address.

    Refuses when a pin already exists unless `force` is set, so it cannot
    silently overwrite a hand-placed marker.
    """
    field :geocode_venue, :venue_summary do
      arg(:force, :boolean, default_value: false)
      middleware(RequireMember, "manager")

      resolve(fn %{force: force}, %{context: ctx} ->
        Venues.geocode_venue(ctx.current_venue, force: force) |> format_errors()
      end)
    end

    @desc """
    Step 1 of a photo upload: reserves a key and returns a presigned PUT.

    The browser then PUTs the bytes to `url` and calls `finalizePhotoUpload`.
    """
    field :request_photo_upload, :upload_ticket do
      arg(:content_type, non_null(:string))
      arg(:byte_size, :integer)
      arg(:kind, :string, default_value: "gallery")
      middleware(RequireMember, "manager")

      resolve(fn args, %{context: ctx} ->
        case Media.request_upload(ctx.venue_id, args) do
          {:ok, ticket} ->
            # `Media` calls it `attachment`; the API calls it `photo`. Naming the
            # mapping here keeps the context's vocabulary out of the schema.
            {:ok,
             %{
               photo: ticket.attachment,
               url: ticket.url,
               headers: header_list(ticket.headers)
             }}

          other ->
            format_errors(other)
        end
      end)
    end

    @desc """
    Step 2 of a photo upload: validates the stored bytes and builds the variants.

    Where a file that is not really an image is caught — a presigned PUT accepts
    whatever the client sent, so this is the first point anything is trusted.
    """
    field :finalize_photo_upload, :photo do
      arg(:id, non_null(:id))
      middleware(RequireMember, "manager")

      resolve(fn %{id: id}, %{context: ctx} ->
        Media.finalize_upload(ctx.venue_id, to_int(id)) |> format_errors()
      end)
    end

    field :delete_photo, :photo do
      arg(:id, non_null(:id))
      middleware(RequireMember, "manager")

      resolve(fn %{id: id}, %{context: ctx} ->
        Media.delete_photo(ctx.venue_id, to_int(id)) |> format_errors()
      end)
    end

    @desc "Promotes one photo to the venue's cover, demoting the previous one."
    field :set_cover_photo, :photo do
      arg(:id, non_null(:id))
      middleware(RequireMember, "manager")

      resolve(fn %{id: id}, %{context: ctx} ->
        Media.set_cover(ctx.venue_id, to_int(id)) |> format_errors()
      end)
    end

    @desc "Applies a gallery display order."
    field :reorder_photos, list_of(:photo) do
      arg(:ids, non_null(list_of(non_null(:id))))
      middleware(RequireMember, "manager")

      resolve(fn %{ids: photo_ids}, %{context: ctx} ->
        Media.reorder_photos(ctx.venue_id, ids(photo_ids)) |> format_errors()
      end)
    end

    field :checkout, :sale do
      arg(:appointment_ids, non_null(list_of(non_null(:id))))
      arg(:tip_cents, :integer)
      arg(:payment_method, :string)

      middleware(RequireMember, "receptionist")

      resolve(fn args, %{context: ctx} ->
        Salon.checkout(
          ctx.venue_id,
          ids(args.appointment_ids),
          args[:tip_cents],
          args[:payment_method]
        )
        |> format_errors()
      end)
    end

    @desc "Books a slot at a venue for the signed-in customer."
    field :book, :booking_result do
      arg(:venue_slug, non_null(:string))
      arg(:service_ids, non_null(list_of(non_null(:id))))
      arg(:staff_id, :string)
      arg(:date, non_null(:date))
      arg(:start_min, non_null(:integer))
      arg(:notes, :string)

      middleware(RequireAuth)

      resolve(fn args, %{context: %{current_user: user}} ->
        with {:ok, venue} <- Venues.get_public_by_slug(args.venue_slug),
             {:ok, client_id} <- Accounts.ensure_client(user, venue.id) do
          args
          |> Map.drop([:venue_slug])
          |> Map.update!(:service_ids, &ids/1)
          |> Map.put(:client_id, client_id)
          |> then(&Salon.book(venue.id, &1))
          |> broadcast_booking()
          |> format_errors()
        end
      end)
    end

    field :sign_up, :auth_payload do
      arg(:email, non_null(:string))
      arg(:password, non_null(:string))
      arg(:first_name, non_null(:string))
      arg(:last_name, :string)
      arg(:phone, :string)

      @desc "Creating a business account: the venue is created with the user as its owner."
      arg(:business_name, :string)

      middleware(RateLimitAuth)

      resolve(fn args, %{context: ctx} ->
        result =
          case args[:business_name] do
            name when is_binary(name) and name != "" ->
              with {:ok, %{user: user}} <- Accounts.sign_up_with_venue(args, name),
                   do: {:ok, user}

            _ ->
              Accounts.sign_up(args)
          end

        case result do
          {:ok, user} -> session_payload(user, ctx)
          {:error, reason} -> format_errors({:error, reason})
        end
      end)
    end

    field :login, :auth_payload do
      arg(:email, non_null(:string))
      arg(:password, non_null(:string))

      middleware(RateLimitAuth)

      resolve(fn %{email: email, password: password}, %{context: ctx} ->
        with {:ok, user} <- Accounts.authenticate(email, password) do
          session_payload(user, ctx)
        end
      end)
    end

    ## --- phone-first auth (F0.2) ---

    @desc """
    Sends a one-time code to a phone number.

    Reports the same success whether or not the number has an account — telling
    them apart would make this an endpoint for enumerating customers.
    """
    field :request_otp, :otp_request do
      arg(:phone, non_null(:string))

      @desc "One of: login (default), verify, reset."
      arg(:purpose, :string, default_value: "login")

      arg(:locale, :string)

      middleware(RateLimitOtp, :request)

      resolve(fn args, %{context: ctx} ->
        opts = [locale: args[:locale]]

        result =
          case args.purpose do
            "reset" -> Accounts.request_password_reset_by_phone(args.phone, opts)
            "verify" -> verify_phone_request(ctx, args.phone, opts)
            _ -> Accounts.request_login_code(args.phone, opts)
          end

        case result do
          {:ok, details} ->
            {:ok,
             %{
               masked_phone: Blastek.Accounts.Phone.mask(details.phone),
               expires_at: details.expires_at,
               resend_after: details.resend_after
             }}

          other ->
            format_errors(other)
        end
      end)
    end

    @desc """
    Exchanges a phone and code for a session.

    A number nobody has used before becomes an account here; `profileComplete`
    tells the client whether to ask for a name next.
    """
    field :verify_otp, :auth_payload do
      arg(:phone, non_null(:string))
      arg(:code, non_null(:string))

      middleware(RateLimitOtp, :verify)

      resolve(fn %{phone: phone, code: code}, %{context: ctx} ->
        case Accounts.verify_login_code(phone, code, session_opts(ctx)) do
          {:ok, tokens} -> {:ok, auth_payload(tokens)}
          other -> format_errors(other)
        end
      end)
    end

    @desc "Fills in the name of an account created by phone."
    field :complete_profile, :user do
      arg(:first_name, non_null(:string))
      arg(:last_name, :string)
      arg(:email, :string)

      middleware(RequireAuth)

      resolve(fn args, %{context: %{current_user: user}} ->
        Accounts.complete_profile(user, args) |> format_errors()
      end)
    end

    @desc "Confirms a phone number for the signed-in account."
    field :confirm_phone, :user do
      arg(:phone, non_null(:string))
      arg(:code, non_null(:string))

      middleware(RequireAuth)
      middleware(RateLimitOtp, :verify)

      resolve(fn %{phone: phone, code: code}, %{context: %{current_user: user}} ->
        Accounts.confirm_phone(user, phone, code) |> format_errors()
      end)
    end

    ## --- sessions ---

    @desc """
    Trades a refresh token for a fresh pair.

    The old pair stops working. Presenting an already-rotated refresh token
    revokes the whole session — it means two parties hold it.
    """
    field :refresh_session, :auth_payload do
      arg(:refresh_token, non_null(:string))

      resolve(fn %{refresh_token: refresh_token}, %{context: ctx} ->
        case Blastek.Accounts.Sessions.refresh(refresh_token, session_opts(ctx)) do
          {:ok, tokens} ->
            {:ok, auth_payload(Map.put(tokens, :user, Accounts.get_user(tokens.session.user_id)))}

          {:error, :reused} ->
            {:error,
             %{
               message: "Your session was ended for security. Please sign in again.",
               code: "session_reused"
             }}

          {:error, _} ->
            {:error, %{message: "Please sign in again.", code: "unauthenticated"}}
        end
      end)
    end

    @desc "Ends the current session."
    field :logout, :boolean do
      resolve(fn _, %{context: ctx} ->
        Blastek.Accounts.Sessions.revoke_token(ctx[:bearer_token])
        {:ok, true}
      end)
    end

    @desc "Ends one other session — the \"log out the phone I lost\" button."
    field :revoke_session, :boolean do
      arg(:id, non_null(:id))

      middleware(RequireAuth)

      resolve(fn %{id: id}, %{context: %{current_user: user}} ->
        case Blastek.Accounts.Sessions.revoke(user.id, to_int(id)) do
          {:ok, _} -> {:ok, true}
          other -> format_errors(other)
        end
      end)
    end

    @desc "Ends every session except this one."
    field :revoke_other_sessions, :integer do
      middleware(RequireAuth)

      resolve(fn _, %{context: ctx} ->
        current = ctx[:current_session]

        {:ok,
         Blastek.Accounts.Sessions.revoke_all(ctx.current_user.id, except: current && current.id)}
      end)
    end

    ## --- password ---

    @desc "Emails a password reset link. Always reports success."
    field :request_password_reset, :boolean do
      arg(:email, non_null(:string))
      arg(:locale, :string)

      middleware(RateLimitAuth)

      resolve(fn args, _ ->
        Accounts.request_password_reset(args.email, locale: args[:locale])
        {:ok, true}
      end)
    end

    field :reset_password, :boolean do
      arg(:token, non_null(:string))
      arg(:password, non_null(:string))

      resolve(fn %{token: token, password: password}, _ ->
        case Accounts.reset_password(token, password) do
          {:ok, _user} -> {:ok, true}
          other -> format_errors(other)
        end
      end)
    end

    @desc "Resets a password with a code sent by SMS — for accounts with no email."
    field :reset_password_by_phone, :boolean do
      arg(:phone, non_null(:string))
      arg(:code, non_null(:string))
      arg(:password, non_null(:string))

      middleware(RateLimitOtp, :verify)

      resolve(fn args, _ ->
        case Accounts.reset_password_by_phone(args.phone, args.code, args.password) do
          {:ok, _user} -> {:ok, true}
          other -> format_errors(other)
        end
      end)
    end

    @desc "Changes the password from inside the account."
    field :change_password, :boolean do
      arg(:current_password, :string)
      arg(:password, non_null(:string))

      middleware(RequireAuth)

      resolve(fn args, %{context: ctx} ->
        # Keeps the session doing the changing; every other device is signed out.
        except = ctx[:current_session] && ctx.current_session.id

        case Accounts.change_password(ctx.current_user, args[:current_password], args.password,
               except: except
             ) do
          {:ok, _user} -> {:ok, true}
          other -> format_errors(other)
        end
      end)
    end

    field :cancel_my_appointment, :appointment do
      arg(:id, non_null(:id))

      middleware(RequireAuth)

      resolve(fn %{id: id}, %{context: %{current_user: user}} ->
        appt = Salon.get_appointment_for_client(to_int(id), Accounts.client_ids(user))

        if appt && Salon.cancellable_by_client?(appt) do
          # `actor: :customer` so the salon is the one notified — the person
          # pressing the button already knows.
          Salon.update_appointment(appt.venue_id, appt.id, %{
            status: "cancelled",
            actor: :customer
          })
          |> format_errors()
        else
          {:error, "This appointment can no longer be cancelled online — please call the salon."}
        end
      end)
    end

    @desc """
    Turns optional messages on or off for the signed-in account.

    Reminders and marketing only. A booking confirmation is not something a
    person can decline and still have a record of their own booking, so it is
    not offered here.
    """
    field :update_notification_prefs, :user do
      arg(:reminders, :boolean)
      arg(:marketing, :boolean)

      middleware(RequireAuth)

      resolve(fn args, %{context: %{current_user: user}} ->
        # Absinthe omits arguments the caller did not supply, so this merges
        # what was sent rather than defaulting the rest to false.
        user |> Notifications.update_prefs(args) |> format_errors()
      end)
    end

    @desc """
    Remembers which language this account reads (E7-T1 / F0.11).

    Saved on the account rather than only in the browser, so somebody who
    switched to Arabic on their phone is not back in French on a laptop — and so
    their WhatsApp reminders arrive in the language they chose, which is the
    half a `localStorage` key cannot do.
    """
    field :update_locale, :user do
      arg(:locale, non_null(:string))

      middleware(RequireAuth)

      resolve(fn %{locale: locale}, %{context: %{current_user: user}} ->
        Accounts.update_locale(user, locale) |> format_errors()
      end)
    end

    ## --- membership management ---

    field :update_member_role, :venue_membership do
      arg(:id, non_null(:id))
      arg(:role, non_null(:string))
      middleware(RequireMember, "owner")

      resolve(fn %{id: id, role: role}, %{context: ctx} ->
        Venues.update_member_role(ctx.venue_id, id, role, ctx.current_user) |> format_errors()
      end)
    end

    field :remove_member, :venue_membership do
      arg(:id, non_null(:id))
      middleware(RequireMember, "owner")

      resolve(fn %{id: id}, %{context: ctx} ->
        Venues.remove_member(ctx.venue_id, id, ctx.current_user) |> format_errors()
      end)
    end

    @desc """
    Invites someone to the team by phone or email.

    Owner-only: handing out access is the one thing a manager must not be able
    to do for themselves.
    """
    field :invite_member, :invitation_created do
      arg(:role, non_null(:string))
      arg(:phone, :string)
      arg(:email, :string)

      @desc "Attach the new member to an existing calendar column."
      arg(:staff_id, :id)

      arg(:locale, :string)

      middleware(RequireMember, "owner")

      resolve(fn args, %{context: ctx} ->
        attrs = Map.update(args, :staff_id, nil, &int_or_nil/1)

        case Invitations.invite(ctx.current_venue, attrs, ctx.current_user) do
          {:ok, created} ->
            {:ok,
             %{invitation: created.invitation, url: created.url, delivered: created.delivered}}

          other ->
            format_errors(other)
        end
      end)
    end

    @desc "Withdraws an invitation that has not been accepted."
    field :revoke_invitation, :invitation do
      arg(:id, non_null(:id))
      middleware(RequireMember, "owner")

      resolve(fn %{id: id}, %{context: ctx} ->
        Invitations.revoke(ctx.venue_id, to_int(id), ctx.current_user) |> format_errors()
      end)
    end

    @desc """
    Redeems an invitation for the signed-in account.

    Requires a session because a membership has to belong to somebody. The web
    flow signs the invitee in first — by code, so they need no password — and
    then calls this.
    """
    field :accept_invitation, :venue_membership do
      arg(:token, non_null(:string))

      middleware(RequireAuth)

      resolve(fn %{token: token}, %{context: %{current_user: user}} ->
        case Invitations.accept(token, user) do
          {:ok, membership} -> {:ok, Repo.preload(membership, [:venue, :user])}
          other -> format_errors(other)
        end
      end)
    end
  end

  ## ---------- subscriptions ----------

  subscription do
    @desc """
    Appointments changing in the active venue — a new online booking, a
    cancellation, a checkout. Lets an open calendar stay current without
    polling, and is the transport the walk-in queue (F1.9) will use.
    """
    field :appointment_changed, :appointment do
      # Subscriptions authorize in `config`, not middleware: the topic *is* the
      # authorization decision, and it has to be made once at subscribe time
      # rather than per delivered event.
      config(fn _args, %{context: context} ->
        case context do
          %{current_user: _, membership: %{role: role}, venue_id: venue_id} ->
            if Venues.role_at_least?(role, "staff"),
              do: {:ok, topic: "venue:#{venue_id}"},
              else: {:error, "Your role does not allow this action."}

          %{current_user: _} ->
            # No venue means no topic; a shared fallback topic here would leak
            # other tenants' bookings.
            {:error, "Select which venue to manage."}

          _ ->
            {:error, "You must be signed in."}
        end
      end)
    end
  end

  # Live updates live in `BlastekWeb.LiveUpdates` — the schema is no longer the
  # only path an appointment changes by.
  defdelegate broadcast(result), to: BlastekWeb.LiveUpdates
  defdelegate broadcast_booking(result), to: BlastekWeb.LiveUpdates

  ## ---------- localization (E7 / F0.11) ----------
  #
  # Owner-written content — a service name, a category, a tagline — is resolved
  # in the reader's language here rather than in the domain, because the locale
  # is a property of the request and `Blastek.Salon` should not have to know
  # who is asking. The fallback chain lives in `Blastek.I18n`; the important
  # part is that it never returns nothing, since a blank service name is a
  # booking flow with an unlabelled button.

  defp localized(field) do
    fn record, _args, %{context: ctx} ->
      {:ok, I18n.translate(record, field, ctx[:locale])}
    end
  end

  defp translations_of(schema) do
    fn record, _args, _res ->
      {:ok, I18n.expose(record, schema.translatable_fields())}
    end
  end

  # `venue_view/1` flattens a venue into a settings map, so the tagline arrives
  # here divorced from the column it is a translation of. This puts it back into
  # the shape `I18n.translate/3` reads.
  defp taglinable(settings) do
    %{tagline: settings[:business_tagline], translations: settings[:translations] || %{}}
  end

  ## ---------- helpers ----------

  @doc false
  # Scoped lookups raise `Ecto.NoResultsError` when a row belongs to another
  # tenant. To the caller that is simply a row that does not exist — surface it
  # as an ordinary "not found" error rather than letting it become a 500, and
  # keep the message identical to a genuinely missing id so the response cannot
  # be used to probe for other venues' record ids.
  defp found(fun) do
    fun.()
  rescue
    Ecto.NoResultsError -> {:error, %{message: "Not found.", code: "not_found"}}
  end

  @max_page 200

  # Clamps client-supplied paging so one request cannot ask for the whole table.
  defp page_args(args) do
    [
      limit: args |> Map.get(:limit, 50) |> min(@max_page) |> max(1),
      offset: args |> Map.get(:offset, 0) |> max(0)
    ]
  end

  # Staff-level members only see their own column on the calendar.
  defp own_staff_scope(%{membership: %{role: "staff", staff_id: staff_id}})
       when not is_nil(staff_id),
       do: [staff_id: staff_id]

  defp own_staff_scope(_), do: []

  # The same narrowing for the client list.
  #
  # A `staff` membership with no calendar column has served nobody. That must
  # not collapse into `staff_id: nil`, which reads as "no restriction" and would
  # hand the venue's whole client list to the least privileged role — so the
  # absence is stated explicitly rather than encoded as a magic id.
  defp own_client_scope(%{membership: %{role: "staff"}} = context) do
    case own_staff_scope(context) do
      [staff_id: staff_id] -> [staff_id: staff_id]
      [] -> [staff_id: :none]
    end
  end

  defp own_client_scope(_), do: []

  defp stat(client, _args, %{context: %{venue_id: venue_id}}, key) do
    batch({__MODULE__, :batch_client_stats, venue_id}, client.id, fn results ->
      {:ok, get_in(results, [client.id, key]) || zero(key)}
    end)
  end

  defp stat(_client, _args, _res, key), do: {:ok, zero(key)}

  defp zero(:total_spent_cents), do: 0
  defp zero(_), do: 0

  @doc false
  def batch_client_stats(venue_id, client_ids), do: Salon.client_stats_for(venue_id, client_ids)

  defp venue_card(venue, _args, _res, key) do
    batch({__MODULE__, :batch_venue_cards, nil}, venue.id, fn results ->
      {:ok, get_in(results, [venue.id, key])}
    end)
  end

  @doc false
  def batch_venue_cards(_, venue_ids), do: Salon.venue_cards_for(venue_ids)

  # Photos are batched for the same reason as the card stats: a results page
  # renders one card per venue, and a per-card query is a query per result.
  defp venue_cover(venue, _args, _res) do
    batch({__MODULE__, :batch_venue_photos, nil}, venue.id, fn results ->
      {:ok, results |> Map.get(venue.id, []) |> Media.cover_url()}
    end)
  end

  defp venue_photos(venue, _args, _res) do
    batch({__MODULE__, :batch_venue_photos, nil}, venue.id, fn results ->
      {:ok, Map.get(results, venue.id, [])}
    end)
  end

  @doc false
  def batch_venue_photos(_, venue_ids), do: Media.photos_for(venue_ids)

  @doc false
  def batch_users(_, user_ids), do: Accounts.get_users(user_ids)

  # Every sign-in path ends the same way: start a session, return the pair.
  defp session_payload(user, context) do
    {:ok, tokens} = Accounts.start_session(user, session_opts(context))
    {:ok, auth_payload(Map.put(tokens, :user, user))}
  end

  defp auth_payload(tokens) do
    %{
      token: tokens.token,
      refresh_token: tokens.refresh_token,
      expires_at: tokens.expires_at,
      user: tokens.user,
      profile_complete: Accounts.profile_complete?(tokens.user)
    }
  end

  # Labels the session with the device that started it, so the sessions list can
  # say "Chrome on Android" instead of showing a row of ids.
  defp session_opts(context) do
    [device: context[:user_agent] || "", ip: context[:client_ip] || ""]
  end

  # Adding a number to an existing account, versus signing in with one. Only the
  # former requires being signed in already.
  defp verify_phone_request(%{current_user: user}, phone, opts),
    do: Accounts.request_phone_verification(user, phone, opts)

  defp verify_phone_request(_context, _phone, _opts),
    do: {:error, "You must be signed in to add a phone number."}

  # Absinthe input objects arrive as maps; `Discovery` takes a plain tuple so it
  # has no opinion about where the coordinates came from.
  defp near_point(%{lat: lat, lng: lng}), do: {lat, lng}
  defp near_point(_), do: nil

  # Read out of the settings JSONB, where a flag may have been written as a
  # boolean or as a string depending on which client wrote it.
  defp women_only?(%{settings: settings}) when is_map(settings) do
    Map.get(settings, "women_only") in [true, "true"]
  end

  defp women_only?(_), do: false

  # JSONB comes back with string keys; the GraphQL layer speaks atoms.
  defp atomize_day(day) do
    %{
      weekday: day["weekday"],
      working: day["working"],
      start_min: day["start_min"],
      end_min: day["end_min"]
    }
  end

  # `venue_summary` is a public type: it comes back from marketplace search and
  # from a venue page. A few of its fields are the venue's own business, so they
  # answer only to a member of that venue or to an admin.
  #
  # Gated on the type rather than left to the queries. Nothing today hands a
  # stranger a pending venue, so nothing leaks — but that is a property of
  # today's queries, and the next one to return summaries would give these away
  # without anybody noticing.
  defp own_venue_field(venue, _args, %{context: ctx}, read) do
    admin? = match?(%{current_user: %{role: "admin"}}, ctx)

    member? =
      ctx |> Map.get(:memberships, []) |> Enum.any?(&(&1.venue_id == venue.id))

    if admin? or member?, do: {:ok, read.(venue)}, else: {:ok, nil}
  end

  defp onboarding_state(%{onboarding: onboarding} = venue) when is_map(onboarding) do
    %{
      current_step: Map.get(onboarding, "current_step"),
      completed: onboarding |> Map.get("completed", []) |> List.wrap(),
      submitted: Map.has_key?(onboarding, "submitted_at"),
      complete: Venues.Onboarding.complete?(venue),
      data: Map.drop(onboarding, ["current_step", "completed", "submitted_at", "updated_at"])
    }
  end

  defp onboarding_state(_),
    do: %{current_step: nil, completed: [], submitted: false, complete: false, data: %{}}

  defp header_list(headers) do
    Enum.map(headers, fn {name, value} -> %{name: name, value: value} end)
  end

  defp ids(list), do: Enum.map(list, &to_int/1)

  defp to_int(v) when is_integer(v), do: v
  defp to_int(v), do: String.to_integer(to_string(v))

  defp int_or_nil(nil), do: nil
  defp int_or_nil(v), do: to_int(v)

  defp loaded_or(%Ecto.Association.NotLoaded{}, default), do: default
  defp loaded_or(value, _), do: value

  # Errors carry `code` and (for validation) `field` alongside the message, so a
  # client can attach the message to the input that caused it and branch on the
  # kind of failure instead of pattern-matching English prose.
  defp format_errors({:ok, value}), do: {:ok, value}

  defp format_errors({:error, %Ecto.Changeset{} = cs}) do
    errors =
      cs
      |> Ecto.Changeset.traverse_errors(&interpolate/1)
      |> Enum.flat_map(fn {field, messages} ->
        Enum.map(messages, fn message ->
          %{
            message: "#{humanize(field)} #{message}",
            code: "validation",
            field: camelize(field)
          }
        end)
      end)

    {:error, errors}
  end

  defp format_errors({:error, list}) when is_list(list), do: {:error, list}
  defp format_errors({:error, %{message: _} = structured}), do: {:error, structured}

  defp format_errors({:error, reason}) do
    message = to_string(reason)
    {:error, %{message: message, code: code_for(message)}}
  end

  # Ecto stores messages as templates ("should be at least %{count} character(s)").
  defp interpolate({message, opts}) do
    Enum.reduce(opts, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  defp humanize(field) do
    field |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp camelize(field) do
    [first | rest] = field |> to_string() |> String.split("_")
    Enum.join([first | Enum.map(rest, &String.capitalize/1)])
  end

  # Best-effort classification of the context layer's plain-string errors.
  # New code should return a structured error directly.
  defp code_for(message) do
    cond do
      message =~ ~r/not found|unknown/i -> "not_found"
      message =~ ~r/just taken|overlaps|already/i -> "conflict"
      message =~ ~r/not authorized|does not allow|signed in/i -> "forbidden"
      message =~ ~r/too many/i -> "rate_limited"
      true -> "error"
    end
  end
end
