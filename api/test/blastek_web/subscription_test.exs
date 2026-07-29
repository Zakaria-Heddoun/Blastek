defmodule BlastekWeb.SubscriptionTest do
  @moduledoc """
  GraphQL subscriptions (E2-T4): a venue's calendar receives its own changes and
  only its own.

  Changes are made through the GraphQL layer rather than the context, because
  that is where publishing happens — and it is the path every real write takes.
  """
  use BlastekWeb.ChannelCase, async: false

  import Blastek.Fixtures

  alias Blastek.Venues
  alias BlastekWeb.Schema

  setup do
    a = venue_fixture("Sub Salon A")
    b = venue_fixture("Sub Salon B")
    %{user: user_a} = member_fixture(a.venue, "owner", "sub-a@example.com")
    %{user: user_b} = member_fixture(b.venue, "owner", "sub-b@example.com")

    %{a: a, b: b, ctx_a: context_for(user_a), ctx_b: context_for(user_b)}
  end

  defp context_for(user) do
    m = user.id |> Venues.list_memberships() |> hd()

    %{
      current_user: user,
      memberships: [m],
      membership: m,
      current_venue: m.venue,
      venue_id: m.venue_id
    }
  end

  defp subscribe(context) do
    {:ok, socket} = Phoenix.ChannelTest.connect(BlastekWeb.UserSocket, %{})
    socket = Absinthe.Phoenix.Socket.put_options(socket, context: context)

    {:ok, _, socket} =
      Phoenix.ChannelTest.subscribe_and_join(socket, "__absinthe__:control", %{})

    ref = push(socket, "doc", %{"query" => "subscription { appointmentChanged { id status } }"})
    assert_reply ref, :ok, reply
    assert %{subscriptionId: _} = reply

    socket
  end

  defp create_appointment(v, context, start_min) do
    mutation = """
    mutation {
      createAppointment(clientId: "#{v.client.id}", staffId: "#{v.staff.id}",
        serviceId: "#{v.service.id}", date: "#{Date.add(Date.utc_today(), 2)}",
        startMin: #{start_min}) { id }
    }
    """

    {:ok, %{data: %{"createAppointment" => appt}}} =
      Absinthe.run(mutation, Schema, context: context)

    appt
  end

  test "a venue receives its own appointment changes", %{a: a, ctx_a: ctx_a} do
    subscribe(ctx_a)
    appt = create_appointment(a, ctx_a, 600)

    assert_push "subscription:data", payload, 2_000
    assert payload.result.data["appointmentChanged"]["id"] == appt["id"]
  end

  test "a venue does not receive another venue's changes", %{b: b, ctx_a: ctx_a, ctx_b: ctx_b} do
    subscribe(ctx_a)

    # A booking at the other venue must not reach this subscriber.
    create_appointment(b, ctx_b, 660)

    refute_push "subscription:data", _payload, 600
  end

  test "status changes are published too", %{a: a, ctx_a: ctx_a} do
    appt = create_appointment(a, ctx_a, 720)
    subscribe(ctx_a)

    {:ok, _} =
      Absinthe.run(
        ~s|mutation { updateAppointment(id: "#{appt["id"]}", status: "confirmed") { id } }|,
        Schema,
        context: ctx_a
      )

    assert_push "subscription:data", payload, 2_000
    assert payload.result.data["appointmentChanged"]["status"] == "confirmed"
  end
end
