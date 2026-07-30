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
  alias Blastek.Discovery
  alias Blastek.Media
  alias Blastek.Salon
  alias Blastek.Venues

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
    field :business_tagline, :string
    field :business_address, :string
    field :business_phone, :string
  end

  object :category do
    field :id, :id
    field :name, :string
    field :sort, :integer
  end

  object :service do
    field :id, :id
    field :category_id, :id
    field :name, :string
    field :description, :string
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
      middleware(RequireMember, "receptionist")

      resolve(fn args, %{context: ctx} ->
        page = page_args(args)

        {:ok,
         %{
           items: Salon.list_clients(ctx.venue_id, args[:q], page),
           total_count: Salon.count_clients(ctx.venue_id, args[:q])
         }}
      end)
    end

    field :client, :client do
      arg(:id, non_null(:id))
      middleware(RequireMember, "receptionist")

      resolve(fn %{id: id}, %{context: ctx} ->
        found(fn -> {:ok, Salon.get_client!(ctx.venue_id, id)} end)
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
      middleware(RequireMember, "manager")

      resolve(fn %{name: name}, %{context: ctx} ->
        Salon.create_category(ctx.venue_id, %{name: name, sort: 99}) |> format_errors()
      end)
    end

    field :create_service, :service do
      arg(:category_id, non_null(:id))
      arg(:name, non_null(:string))
      arg(:description, :string)
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
        case Salon.get_appointment_for_client(to_int(id), Accounts.client_ids(user)) do
          %{status: status} = appt when status in ["booked", "confirmed"] ->
            Salon.update_appointment(appt.venue_id, appt.id, %{status: "cancelled"})
            |> format_errors()

          _ ->
            {:error, "This appointment can no longer be cancelled online."}
        end
      end)
    end

    ## --- membership management ---

    field :update_member_role, :venue_membership do
      arg(:id, non_null(:id))
      arg(:role, non_null(:string))
      middleware(RequireMember, "owner")

      resolve(fn %{id: id, role: role}, %{context: ctx} ->
        Venues.update_member_role(ctx.venue_id, id, role) |> format_errors()
      end)
    end

    field :remove_member, :venue_membership do
      arg(:id, non_null(:id))
      middleware(RequireMember, "owner")

      resolve(fn %{id: id}, %{context: ctx} ->
        Venues.remove_member(ctx.venue_id, id) |> format_errors()
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

  # Publishes an appointment change to that venue's subscribers. Called after
  # the write commits, so a subscriber that immediately re-queries cannot
  # observe a state older than the event. Failures are swallowed: a dropped
  # notification must never fail the booking that caused it.
  defp publish_appointment(%{venue_id: venue_id} = appointment) do
    Absinthe.Subscription.publish(BlastekWeb.Endpoint, appointment,
      appointment_changed: "venue:#{venue_id}"
    )

    :ok
  rescue
    _ -> :ok
  end

  defp broadcast({:ok, appointment} = result) do
    publish_appointment(appointment)
    result
  end

  defp broadcast(other), do: other

  # A booking creates several appointments under one reference; the calendar
  # needs each of them.
  defp broadcast_booking({:ok, %{appointments: appointments}} = result) do
    Enum.each(appointments, &publish_appointment/1)
    result
  end

  defp broadcast_booking(other), do: other

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
