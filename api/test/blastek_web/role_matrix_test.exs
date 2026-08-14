defmodule BlastekWeb.RoleMatrixTest do
  @moduledoc """
  Every dashboard operation against every role (E4-T2 / F0.3).

  F0.3 asks for exactly this table, and it is worth having as a table rather
  than as prose: the permission model is a product decision ("a receptionist
  must not see revenue"), and a decision spread across forty `middleware` lines
  is one nobody can review. Here it is one screen.

  The matrix is also a **regression net for the wrong direction**. A test that
  only checks the allowed cases will happily pass while a field is quietly
  opened to everyone; each row below asserts the refusals too.
  """
  use Blastek.DataCase, async: true
  import Ecto.Query

  import Blastek.Fixtures

  alias Blastek.Venues
  alias BlastekWeb.Schema

  @roles ~w(staff receptionist manager owner)

  # {field identifier, graphql, lowest role that may run it}
  #
  # The identifier is the schema's own, so `the matrix is complete` below can
  # compare this table against the schema and fail when a new gated field has
  # been added without being reviewed here.
  @operations [
    # --- reads a working stylist needs ---
    {:current_venue, "{ currentVenue { slug } }", "staff"},
    {:settings, "{ settings { businessName } }", "staff"},
    {:categories, "{ categories { id } }", "staff"},
    {:services, "{ services { id } }", "staff"},
    {:staff, "{ staff { id } }", "staff"},
    {:appointments, ~s|{ appointments(from: "2026-07-01", to: "2026-07-07") { id } }|, "staff"},
    {:staff_blocks, ~s|{ staffBlocks(from: "2026-07-01", to: "2026-07-07") { id } }|, "staff"},
    {:staff_block_conflicts,
     ~s|mutation { staffBlockConflicts(staffId: "1", kind: "time_off", date: "2026-07-01") { id } }|,
     "staff"},
    {:create_staff_block,
     ~s|mutation { createStaffBlock(staffId: "1", kind: "time_off", date: "2026-07-01") { id } }|,
     "staff"},
    {:delete_staff_block, ~s|mutation { deleteStaffBlock(id: "1") }|, "staff"},
    # Narrowed to their own clients rather than refused — see F0.3's "limited CRM".
    {:clients, "{ clients(limit: 5) { totalCount } }", "staff"},
    {:client, ~s|{ client(id: "1") { id } }|, "staff"},

    # --- the front desk ---
    {:create_appointment,
     ~s|mutation { createAppointment(clientId: "1", staffId: "1", serviceId: "1", | <>
       ~s|date: "2026-07-01", startMin: 600) { id } }|, "receptionist"},
    {:update_appointment, ~s|mutation { updateAppointment(id: "1", status: "confirmed") { id } }|,
     "receptionist"},
    {:create_client, ~s|mutation { createClient(input: {firstName: "X"}) { id } }|,
     "receptionist"},
    {:update_client, ~s|mutation { updateClient(id: "1", input: {firstName: "X"}) { id } }|,
     "receptionist"},
    {:checkout, ~s|mutation { checkout(appointmentIds: ["1"]) { id } }|, "receptionist"},

    # --- the money, the catalog and the team roster ---
    {:sales, ~s|{ sales(from: "2026-07-01", limit: 5) { totalCount } }|, "manager"},
    {:report_summary, "{ reportSummary { revenueCents } }", "manager"},
    {:create_service,
     ~s|mutation { createService(categoryId: "1", name: "X", durationMin: 30, | <>
       ~s|priceCents: 1000) { id } }|, "manager"},
    {:update_service, ~s|mutation { updateService(id: "1", name: "X") { id } }|, "manager"},
    {:create_category, ~s|mutation { createCategory(name: "X") { id } }|, "manager"},
    {:update_category, ~s|mutation { updateCategory(id: "1", name: "X") { id } }|, "manager"},
    {:create_staff, ~s|mutation { createStaff(name: "X") { id } }|, "manager"},
    {:update_staff, ~s|mutation { updateStaff(id: "1", name: "X") { id } }|, "manager"},
    {:venue_members, "{ venueMembers { id } }", "manager"},
    {:pending_invitations, "{ pendingInvitations { id } }", "manager"},

    # --- the venue's public face (E8) ---
    {:venue_photos, "{ venuePhotos { id } }", "manager"},
    {:request_photo_upload,
     ~s|mutation { requestPhotoUpload(contentType: "image/jpeg") { url } }|, "manager"},
    {:finalize_photo_upload, ~s|mutation { finalizePhotoUpload(id: "1") { id } }|, "manager"},
    {:delete_photo, ~s|mutation { deletePhoto(id: "1") { id } }|, "manager"},
    {:set_cover_photo, ~s|mutation { setCoverPhoto(id: "1") { id } }|, "manager"},
    {:reorder_photos, ~s|mutation { reorderPhotos(ids: ["1"]) { id } }|, "manager"},
    {:set_venue_location, "mutation { setVenueLocation(lat: 33.0, lng: -7.0) { id } }",
     "manager"},
    {:geocode_venue, "mutation { geocodeVenue { id } }", "manager"},
    {:set_venue_women_only, "mutation { setVenueWomenOnly(value: true) { id } }", "manager"},

    # --- opening hours and closures (E5) ---
    {:venue_closures, "{ venueClosures { id } }", "staff"},
    {:venue_hour_templates, "{ venueHourTemplates { name active } }", "manager"},
    {:venue_week, "{ venueWeek { weekday open close } }", "manager"},
    {:closure_conflicts, ~s|{ closureConflicts(date: "2026-08-01") { id } }|, "manager"},
    {:create_closure, ~s|mutation { createClosure(date: "2026-08-01") { id } }|, "manager"},
    {:delete_closure, ~s|mutation { deleteClosure(id: "1") { id } }|, "manager"},
    {:save_hour_template,
     ~s|mutation { saveHourTemplate(name: "ramadan", days: [{weekday: 1, working: true, | <>
       ~s|startMin: 1260, endMin: 1470}]) { name } }|, "manager"},
    {:set_hour_template, ~s|mutation { setHourTemplate(name: "default") { name } }|, "manager"},
    {:update_venue_settings, "mutation { updateVenueSettings(input: {slotStepMin: 30}) { id } }",
     "manager"},

    # --- onboarding (E5) ---
    {:apply_service_templates, ~s|mutation { applyServiceTemplates(templateIds: ["1"]) { id } }|,
     "manager"},
    {:update_onboarding, ~s|mutation { updateOnboarding(step: "basics") { id } }|, "manager"},
    {:submit_venue, "mutation { submitVenue { id } }", "owner"},

    # --- handing out access, and the venue itself ---
    {:update_venue, ~s|mutation { updateVenue(input: {name: "X"}) { id } }|, "owner"},
    {:invite_member, ~s|mutation { inviteMember(role: "staff", phone: "0611111111") { url } }|,
     "owner"},
    {:revoke_invitation, ~s|mutation { revokeInvitation(id: "1") { id } }|, "owner"},
    {:update_member_role, ~s|mutation { updateMemberRole(id: "1", role: "staff") { id } }|,
     "owner"},
    {:remove_member, ~s|mutation { removeMember(id: "1") { id } }|, "owner"},
    {:audit_log, "{ auditLog { id } }", "owner"},

    # --- reviews (E10) ---
    #
    # Replying publishes under the salon's name and flagging asks the platform
    # to act on the salon's behalf, so both sit with a manager. A stylist reads
    # reviews on the public page like anybody else; what they must not do is
    # answer one as the venue.
    {:venue_reviews, "{ venueReviews { totalCount } }", "staff"},
    {:reply_to_review, ~s|mutation { replyToReview(id: "1", text: "Merci") { id } }|, "manager"},
    {:flag_review, ~s|mutation { flagReview(id: "1", reason: "abusive") { id } }|, "manager"}
  ]

  # Fields gated on `RequireAdmin` rather than on a venue role: they cross
  # venues, which is precisely why no venue role may reach them. Declared here
  # so that adding one without noticing fails the suite.
  @admin_operations ~w(
    admin_venues
    approve_venue
    flagged_reviews
    moderate_review
    notification_log
    reject_venue
    venue_duplicates
    venue_review_queue
  )

  setup do
    venue = venue_fixture("Matrix Salon")

    members =
      Map.new(@roles, fn role ->
        %{user: user} = member_fixture(venue.venue, role, "#{role}-#{unique()}@example.com")

        # The  member owns the venue's calendar column. A stylist who
        # takes appointments is what that role *is*, and without the link the
        # rows that turn on "your own" — the limited CRM, your own time off —
        # cannot be exercised at all.
        if role == "staff" do
          Blastek.Repo.update_all(
            from(m in Blastek.Venues.VenueMember,
              where: m.user_id == ^user.id and m.venue_id == ^venue.venue.id
            ),
            set: [staff_id: venue.staff.id]
          )
        end

        {role, user}
      end)

    %{venue: venue, members: members}
  end

  defp unique, do: System.unique_integer([:positive])

  defp run(query, user, venue) do
    Absinthe.run(query, Schema,
      context: %{
        current_user: user,
        current_venue: venue.venue,
        venue_id: venue.venue.id,
        membership: Venues.get_membership(user.id, venue.venue.id),
        memberships: Venues.list_memberships(user.id),
        client_ip: "10.0.0.1"
      }
    )
  end

  # Authorization is the only thing under test, so a request that got far enough
  # to fail on its *arguments* has passed. Rejections carry a `code`, and the
  # three that mean "not allowed" are the ones that matter.
  #
  # A query that fails GraphQL *validation* is a different matter: it never
  # reaches the middleware at all, so it would look permitted to every role and
  # the row would quietly assert nothing. Those are raised rather than counted.
  defp authorized?(label, result) do
    case result do
      {:ok, %{errors: errors}} ->
        assert_no_validation_errors(label, errors)
        not Enum.any?(errors, &(Map.get(&1, :code) in ~w(forbidden unauthenticated no_venue)))

      _ ->
        true
    end
  end

  @validation_markers ["Unknown argument", "Expected type", "Cannot query field", "Unknown field"]

  defp assert_no_validation_errors(label, errors) do
    broken =
      Enum.filter(errors, fn error ->
        message = Map.get(error, :message, "")

        Map.get(error, :code) == nil and
          Enum.any?(@validation_markers, &String.contains?(message, &1))
      end)

    if broken != [] do
      flunk("""
      The matrix row for #{label} is not a valid query, so it never reached the
      permission middleware and would pass for every role:

      #{Enum.map_join(broken, "\n", &("  - " <> Map.get(&1, :message, "")))}
      """)
    end
  end

  describe "role matrix" do
    for {label, query, minimum} <- @operations do
      test "#{label} requires #{minimum}", %{venue: venue, members: members} do
        query = unquote(query)
        minimum = unquote(minimum)

        for role <- @roles do
          allowed = Venues.role_at_least?(role, minimum)
          result = run(query, members[role], venue)

          assert authorized?(unquote(label), result) == allowed,
                 """
                 #{unquote(label)} with role #{role}: expected #{if allowed, do: "allowed", else: "refused"}.
                 #{inspect(result)}
                 """
        end
      end
    end
  end

  describe "the matrix is complete" do
    test "every dashboard field is covered by a row above" do
      covered = MapSet.new(@operations, fn {identifier, _, _} -> to_string(identifier) end)

      # Pulled from the schema itself, so adding a gated field without adding a
      # row here fails rather than silently going unreviewed.
      gated =
        [
          Absinthe.Schema.lookup_type(Schema, :query),
          Absinthe.Schema.lookup_type(Schema, :mutation)
        ]
        |> Enum.flat_map(fn object ->
          object.fields
          |> Map.values()
          |> Enum.filter(&member_gated?(&1, object))
        end)
        |> MapSet.new(& &1.name)

      # Without this the check passes vacuously: if the middleware pattern below
      # ever stops matching, `gated` is empty, nothing is "missing", and the
      # completeness guarantee silently evaporates.
      assert MapSet.size(gated) >= 20,
             "schema introspection found only #{MapSet.size(gated)} gated fields — " <>
               "`member_gated?/1` has probably stopped matching"

      missing = MapSet.difference(gated, covered)

      assert MapSet.size(missing) == 0,
             "these role-gated fields have no row in the matrix: #{inspect(MapSet.to_list(missing))}"
    end

    test "every platform-admin field refuses a venue owner", ctx do
      # `RequireMember` and `RequireAdmin` are different gates and the table
      # above only reviews the first. An admin-only field is the *more*
      # dangerous of the two to add unnoticed — it is admin-only because it
      # crosses venues — so it gets its own sweep rather than its own row.
      admin_fields =
        [{"query", :query}, {"mutation", :mutation}]
        |> Enum.flat_map(fn {keyword, type} ->
          object = Absinthe.Schema.lookup_type(Schema, type)

          object.fields
          |> Map.values()
          |> Enum.filter(&admin_gated?(&1, object))
          |> Enum.map(&{keyword, &1})
        end)

      assert length(admin_fields) >= 4,
             "introspection found only #{length(admin_fields)} admin-gated fields — " <>
               "`admin_gated?/2` has probably stopped matching"

      # The set is declared, not merely counted. Comparing introspection against
      # a written list is what makes this a completeness check rather than a
      # spot check: adding a cross-venue field and forgetting `RequireAdmin`
      # fails here, and so does quietly removing the gate from one of these.
      assert MapSet.new(admin_fields, fn {_keyword, field} -> field.name end) ==
               MapSet.new(@admin_operations),
             "the set of platform-admin fields changed — review the addition, then update " <>
               "`@admin_operations`"

      owner = ctx.members["owner"]

      for {keyword, field} <- admin_fields do
        result = run(probe_query(keyword, field), owner, ctx.venue)

        refute authorized?(field.name, result),
               "#{field.name} is gated on RequireAdmin but a venue owner got through"
      end
    end
  end

  # A syntactically valid query for a field whose arguments we do not care
  # about. Required arguments get a placeholder of the right *type* — omitting
  # them fails GraphQL validation before the middleware runs, which
  # `authorized?/2` rightly refuses to count as a refusal.
  defp probe_query(keyword, field) do
    args =
      field.args
      |> Map.values()
      |> Enum.filter(&match?(%Absinthe.Type.NonNull{}, &1.type))
      |> Enum.map_join(", ", &"#{external(&1.name)}: #{placeholder(&1.type)}")

    arguments = if args == "", do: "", else: "(#{args})"
    "#{keyword} { #{external(field.name)}#{arguments}#{selection(field)} }"
  end

  # Introspection reports a field's internal name; a document has to use the
  # external one the adapter exposes.
  defp external(name),
    do: Absinthe.Adapter.LanguageConventions.to_external_name(name, :field)

  defp placeholder(%Absinthe.Type.NonNull{of_type: inner}), do: placeholder(inner)
  defp placeholder(%Absinthe.Type.List{}), do: "[]"

  defp placeholder(type) do
    case Absinthe.Schema.lookup_type(Schema, type) do
      %{name: "Int"} -> "1"
      %{name: "Boolean"} -> "false"
      %{name: "Float"} -> "1.0"
      %{name: "Date"} -> ~s|"2026-07-01"|
      _ -> ~s|"1"|
    end
  end

  # Scalars take no selection set; object types require one.
  defp selection(field) do
    case Absinthe.Schema.lookup_type(Schema, field.type) do
      %Absinthe.Type.Object{} -> " { __typename }"
      _ -> ""
    end
  end

  defp admin_gated?(field, object) do
    Schema
    |> Absinthe.Middleware.expand(field.middleware, field, object)
    |> Enum.flat_map(fn
      {{Absinthe.Middleware, :shim}, _} = shim -> Absinthe.Middleware.unshim([shim], Schema)
      plain -> [plain]
    end)
    |> Enum.any?(fn
      {{BlastekWeb.Schema.RequireAdmin, :call}, _} -> true
      BlastekWeb.Schema.RequireAdmin -> true
      _ -> false
    end)
  end

  # Absinthe stores a field's middleware behind a lazy shim, so the declared
  # entries only appear after `expand` and `unshim`. Reading the raw list finds
  # nothing — which is exactly the vacuous pass the size assertion above guards
  # against.
  defp member_gated?(field, object) do
    Schema
    |> Absinthe.Middleware.expand(field.middleware, field, object)
    # `unshim/2` takes the shim entry on its own, so each one is resolved
    # individually and the already-plain entries pass through.
    |> Enum.flat_map(fn
      {{Absinthe.Middleware, :shim}, _} = shim -> Absinthe.Middleware.unshim([shim], Schema)
      plain -> [plain]
    end)
    |> Enum.any?(fn
      {{BlastekWeb.Schema.RequireMember, :call}, _minimum} -> true
      _ -> false
    end)
  end
end
