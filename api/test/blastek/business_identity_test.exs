defmodule Blastek.BusinessIdentityTest do
  use Blastek.DataCase, async: true

  import Blastek.Fixtures

  alias Blastek.Accounts
  alias Blastek.Venues

  test "an existing customer becomes a venue owner without creating a second user" do
    customer = user_fixture("customer-owner@example.com")

    assert {:ok, %{user: same_user, venue: venue}} =
             Accounts.sign_up_with_venue(
               %{
                 email: customer.email,
                 password: "blastek123",
                 first_name: "Ignored replacement"
               },
               "Customer's Salon"
             )

    assert same_user.id == customer.id
    assert Accounts.get_by_email(customer.email).id == customer.id
    assert Venues.get_membership(customer.id, venue.id).role == "owner"
  end

  test "the existing customer's password is required before adding a venue" do
    customer = user_fixture("customer-wrong-password@example.com")

    assert {:error, "Invalid email or password."} =
             Accounts.sign_up_with_venue(
               %{email: customer.email, password: "wrong-password", first_name: "Ignored"},
               "Must Not Exist"
             )

    assert Venues.list_memberships(customer.id) == []
    assert Venues.get_by_slug("must-not-exist") == nil
  end
end
