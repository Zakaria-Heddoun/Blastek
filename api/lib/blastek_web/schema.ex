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
  alias Blastek.Salon
  alias Blastek.Venues
  alias BlastekWeb.Schema.{RateLimitAuth, RequireAdmin, RequireAuth, RequireMember}

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
  end

  @desc "Public marketplace view of one venue."
  object :venue do
    field :id, :id
    field :slug, :string
    field :city, :string
    field :status, :string
    field :settings, :settings
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

    @desc "Venues this account administers (empty for pure customers)."
    field :venues, list_of(:venue_membership) do
      resolve(fn user, _, _ -> {:ok, Venues.list_memberships(user.id)} end)
    end
  end

  object :auth_payload do
    field :token, :string
    field :user, :user
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

    @desc "Active venues on the marketplace."
    field :venues, list_of(:venue_summary) do
      resolve(fn _, _ -> {:ok, Venues.list_venues(status: "active")} end)
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

      resolve(fn args, _ ->
        result =
          case args[:business_name] do
            name when is_binary(name) and name != "" ->
              with {:ok, %{user: user}} <- Accounts.sign_up_with_venue(args, name),
                   do: {:ok, user}

            _ ->
              Accounts.sign_up(args)
          end

        case result do
          {:ok, user} -> {:ok, %{token: Accounts.token_for(user), user: user}}
          {:error, reason} -> format_errors({:error, reason})
        end
      end)
    end

    field :login, :auth_payload do
      arg(:email, non_null(:string))
      arg(:password, non_null(:string))

      middleware(RateLimitAuth)

      resolve(fn %{email: email, password: password}, _ ->
        with {:ok, user} <- Accounts.authenticate(email, password) do
          {:ok, %{token: Accounts.token_for(user), user: user}}
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
