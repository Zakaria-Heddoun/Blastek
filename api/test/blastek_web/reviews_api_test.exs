defmodule BlastekWeb.ReviewsApiTest do
  @moduledoc """
  Reviews over the wire (E10-T2, E10-T3 / F0.8).

  `Blastek.ReviewsTest` covers the rules. This covers the two things that can
  only go wrong at the edge: that the **signed link works without a session**,
  which is the entire delivery mechanism for F0.8, and that a hidden review is
  gone from every public query rather than from the one the domain test happened
  to call.
  """
  use BlastekWeb.ConnCase, async: true

  import Blastek.Fixtures

  alias Blastek.Accounts.Sessions
  alias Blastek.Clock
  alias Blastek.Notifications.ActionToken
  alias Blastek.Repo
  alias Blastek.Salon
  alias Blastek.Salon.Reviews

  setup do
    v = venue_fixture("API Review Salon #{System.unique_integer([:positive])}")
    n = System.unique_integer([:positive])

    customer = user_fixture("rev-cust-#{n}@example.com")
    {:ok, customer_tokens} = Sessions.issue(customer)

    # The client row the salon holds, linked to the customer's account — that
    # link is what turns "a booking" into "your booking".
    {:ok, client} =
      Salon.create_client(v.venue.id, %{
        first_name: "Yasmine",
        last_name: "Cherkaoui",
        email: customer.email
      })

    client = client |> Ecto.Changeset.change(user_id: customer.id) |> Repo.update!()

    %{user: owner} = member_fixture(v.venue, "owner", "rev-owner-#{n}@example.com")
    {:ok, owner_tokens} = Sessions.issue(owner)

    admin = admin_fixture("rev-admin-#{n}@example.com")
    {:ok, admin_tokens} = Sessions.issue(admin)

    %{
      v: v,
      client: client,
      customer: customer_tokens.token,
      owner: owner_tokens.token,
      admin: admin_tokens.token
    }
  end

  defp gql(conn, query, opts) do
    conn =
      Enum.reduce(opts[:headers] || [], conn, fn {name, value}, acc ->
        put_req_header(acc, name, value)
      end)

    conn =
      if token = opts[:as],
        do: put_req_header(conn, "authorization", "Bearer #{token}"),
        else: conn

    conn
    |> post("/api/graphql", %{query: query, variables: opts[:variables] || %{}})
    |> json_response(200)
  end

  defp visit(v, client_id, opts \\ []) do
    ref = "BK-W#{System.unique_integer([:positive])}"

    appointment =
      Repo.insert!(%Salon.Appointment{
        venue_id: v.venue.id,
        booking_ref: ref,
        client_id: client_id,
        staff_id: v.staff.id,
        service_id: v.service.id,
        date: opts[:date] || Date.add(Clock.today(), -1),
        start_min: 600,
        end_min: 660,
        price_cents: v.service.price_cents,
        status: "confirmed"
      })

    {:ok, _} = Salon.checkout(v.venue.id, [appointment.id], 0, "cash")
    %{ref: ref, appointment: appointment}
  end

  @create """
  mutation($ref: String!, $rating: Int!, $comment: String) {
    createReview(bookingRef: $ref, rating: $rating, comment: $comment) {
      id rating comment clientName status locale
    }
  }
  """

  describe "a signed-in customer" do
    test "reviews their own visit", ctx do
      %{ref: ref} = visit(ctx.v, ctx.client.id)

      body =
        gql(ctx.conn, @create,
          as: ctx.customer,
          variables: %{"ref" => ref, "rating" => 5, "comment" => "Impeccable"}
        )

      review = body["data"]["createReview"]
      assert review["rating"] == 5
      assert review["comment"] == "Impeccable"
      # Never the full name, even to the person who wrote it.
      assert review["clientName"] == "Yasmine C."
      assert review["status"] == "visible"
    end

    test "cannot review a booking that is not theirs", ctx do
      {:ok, stranger} =
        Salon.create_client(ctx.v.venue.id, %{first_name: "Someone", last_name: "Else"})

      %{ref: ref} = visit(ctx.v, stranger.id)

      body = gql(ctx.conn, @create, as: ctx.customer, variables: %{"ref" => ref, "rating" => 5})

      assert body["data"]["createReview"] == nil
      assert hd(body["errors"])["message"] =~ "could not find that visit"
    end

    test "is told which rule stopped them, not a single vague message", ctx do
      %{ref: ref} = visit(ctx.v, ctx.client.id)
      gql(ctx.conn, @create, as: ctx.customer, variables: %{"ref" => ref, "rating" => 5})

      body = gql(ctx.conn, @create, as: ctx.customer, variables: %{"ref" => ref, "rating" => 1})
      assert hd(body["errors"])["message"] =~ "already reviewed"

      %{ref: stale} = visit(ctx.v, ctx.client.id, date: Date.add(Clock.today(), -30))
      body = gql(ctx.conn, @create, as: ctx.customer, variables: %{"ref" => stale, "rating" => 5})
      assert hd(body["errors"])["message"] =~ "14 days"
    end

    test "signing in at all is required", ctx do
      %{ref: ref} = visit(ctx.v, ctx.client.id)
      body = gql(ctx.conn, @create, variables: %{"ref" => ref, "rating" => 5})

      assert body["data"]["createReview"] == nil
      assert body["errors"] != []
    end

    test "sees their unreviewed visits as prompts", ctx do
      %{ref: ref} = visit(ctx.v, ctx.client.id)

      body =
        gql(ctx.conn, "{ myReviewableVisits { bookingRef venueName serviceName date } }",
          as: ctx.customer
        )

      assert [visit] = body["data"]["myReviewableVisits"]
      assert visit["bookingRef"] == ref
      assert visit["venueName"] == ctx.v.venue.name
    end
  end

  describe "the signed link from WhatsApp" do
    @from_link """
    mutation($token: String!, $rating: Int!, $comment: String) {
      createReviewFromLink(token: $token, rating: $rating, comment: $comment) {
        id rating clientName
      }
    }
    """

    test "resolves to the visit without a session", ctx do
      %{appointment: appointment} = visit(ctx.v, ctx.client.id)
      token = ActionToken.sign(appointment.id, :review)

      body =
        gql(
          ctx.conn,
          "query($t: String!) { reviewInvitation(token: $t) { bookingRef venueName serviceName error } }",
          variables: %{"t" => token}
        )

      invitation = body["data"]["reviewInvitation"]
      assert invitation["venueName"] == ctx.v.venue.name
      assert invitation["serviceName"] == ctx.v.service.name
      assert invitation["error"] == nil
    end

    test "writes the review without a session", ctx do
      %{appointment: appointment, ref: ref} = visit(ctx.v, ctx.client.id)
      token = ActionToken.sign(appointment.id, :review)

      body =
        gql(ctx.conn, @from_link,
          variables: %{"token" => token, "rating" => 4, "comment" => "Bien"}
        )

      assert body["data"]["createReviewFromLink"]["rating"] == 4
      assert Reviews.count(ctx.v.venue.id) == 1
      assert {:error, :already_reviewed} = Reviews.eligibility(ctx.client.id, ref)
    end

    test "a confirm token is not a review token", ctx do
      %{appointment: appointment} = visit(ctx.v, ctx.client.id)
      token = ActionToken.sign(appointment.id, :confirm)

      body = gql(ctx.conn, @from_link, variables: %{"token" => token, "rating" => 5})

      assert body["data"]["createReviewFromLink"] == nil
      assert hd(body["errors"])["message"] =~ "no longer valid"
    end

    test "a used link says so rather than failing on submit", ctx do
      %{appointment: appointment, ref: ref} = visit(ctx.v, ctx.client.id)
      {:ok, _} = Reviews.create(ctx.client.id, ref, %{rating: 5})
      token = ActionToken.sign(appointment.id, :review)

      body =
        gql(ctx.conn, "query($t: String!) { reviewInvitation(token: $t) { venueName error } }",
          variables: %{"t" => token}
        )

      assert body["data"]["reviewInvitation"]["error"] =~ "already reviewed"
    end

    test "a forged token resolves to nothing", ctx do
      body =
        gql(ctx.conn, "query($t: String!) { reviewInvitation(token: $t) { venueName error } }",
          variables: %{"t" => "not-a-token"}
        )

      assert body["data"]["reviewInvitation"]["venueName"] == nil
      assert body["data"]["reviewInvitation"]["error"] =~ "no longer valid"
    end
  end

  describe "the venue page" do
    setup ctx do
      %{ref: ref} = visit(ctx.v, ctx.client.id)
      {:ok, review} = Reviews.create(ctx.client.id, ref, %{rating: 5, comment: "Super"})
      Map.put(ctx, :review, review)
    end

    @venue """
    query($slug: String!) {
      venue(slug: $slug) {
        rating
        reviewCount
        reviews { id rating comment clientName reply status }
        reviewPage(limit: 5) { totalCount items { id } }
      }
    }
    """

    test "shows the review, the rating and the count", ctx do
      venue = gql(ctx.conn, @venue, variables: %{"slug" => ctx.v.venue.slug})["data"]["venue"]

      assert venue["rating"] == 5.0
      assert venue["reviewCount"] == 1
      assert hd(venue["reviews"])["comment"] == "Super"
      assert venue["reviewPage"]["totalCount"] == 1
    end

    test "the owner's reply comes back with it", ctx do
      body =
        gql(
          ctx.conn,
          "mutation($id: ID!, $t: String!) { replyToReview(id: $id, text: $t) { reply replyEditable } }",
          as: ctx.owner,
          variables: %{"id" => to_string(ctx.review.id), "t" => "Merci beaucoup !"}
        )

      assert body["data"]["replyToReview"]["reply"] == "Merci beaucoup !"
      assert body["data"]["replyToReview"]["replyEditable"] == true

      venue = gql(ctx.conn, @venue, variables: %{"slug" => ctx.v.venue.slug})["data"]["venue"]
      assert hd(venue["reviews"])["reply"] == "Merci beaucoup !"
    end

    test "flagging leaves it on the page — reporting is not removing", ctx do
      gql(ctx.conn, "mutation($id: ID!) { flagReview(id: $id, reason: \"abusive\") { status } }",
        as: ctx.owner,
        variables: %{"id" => to_string(ctx.review.id)}
      )

      venue = gql(ctx.conn, @venue, variables: %{"slug" => ctx.v.venue.slug})["data"]["venue"]

      assert length(venue["reviews"]) == 1
      assert hd(venue["reviews"])["status"] == "flagged"
      assert venue["rating"] == 5.0
    end

    test "hiding removes it from every public field at once", ctx do
      body =
        gql(
          ctx.conn,
          "mutation($id: ID!) { moderateReview(id: $id, verdict: \"hide\", reason: \"spam\") { status } }",
          as: ctx.admin,
          variables: %{"id" => to_string(ctx.review.id)}
        )

      assert body["data"]["moderateReview"]["status"] == "hidden"

      venue = gql(ctx.conn, @venue, variables: %{"slug" => ctx.v.venue.slug})["data"]["venue"]

      assert venue["reviews"] == []
      assert venue["reviewPage"]["totalCount"] == 0
      assert venue["rating"] == 0.0
      assert venue["reviewCount"] == 0
    end

    test "only a platform admin may moderate", ctx do
      body =
        gql(
          ctx.conn,
          "mutation($id: ID!) { moderateReview(id: $id, verdict: \"hide\") { status } }",
          as: ctx.owner,
          variables: %{"id" => to_string(ctx.review.id)}
        )

      assert body["data"]["moderateReview"] == nil
      assert body["errors"] != []
      assert Repo.get(Salon.Review, ctx.review.id).status == "visible"
    end

    test "the flagged queue is the admin's, not the owner's", ctx do
      gql(ctx.conn, "mutation($id: ID!) { flagReview(id: $id, reason: \"spam\") { status } }",
        as: ctx.owner,
        variables: %{"id" => to_string(ctx.review.id)}
      )

      assert gql(ctx.conn, "{ flaggedReviews { id } }", as: ctx.owner)["data"]["flaggedReviews"] ==
               nil

      assert length(
               gql(ctx.conn, "{ flaggedReviews { id comment } }", as: ctx.admin)["data"][
                 "flaggedReviews"
               ]
             ) == 1
    end
  end
end
