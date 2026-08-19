defmodule BlastekWeb.CustomerAccountApiTest do
  use Blastek.DataCase, async: true

  import Blastek.Fixtures

  alias Blastek.Media
  alias Blastek.Storage
  alias BlastekWeb.Schema

  setup do
    user = user_fixture("customer-account@example.com", %{first_name: "Before"})
    %{user: user, context: %{current_user: user}}
  end

  defp run(query, context), do: Absinthe.run(query, Schema, context: context)

  defp jpeg do
    {:ok, image} = Image.new(300, 300, color: [70, 100, 140])
    {:ok, binary} = Image.write(image, :memory, suffix: ".jpg", quality: 80)
    binary
  end

  describe "updateProfile" do
    test "updates only the signed-in user's editable identity", %{context: context} do
      assert {:ok, %{data: %{"updateProfile" => profile}}} =
               run(
                 """
                 mutation {
                   updateProfile(firstName: "Zakaria", lastName: "Heddoun", email: "z@example.com") {
                     firstName lastName email
                   }
                 }
                 """,
                 context
               )

      assert profile == %{
               "firstName" => "Zakaria",
               "lastName" => "Heddoun",
               "email" => "z@example.com"
             }
    end

    test "reports a duplicate email on the email field", %{context: context} do
      user_fixture("already-used@example.com")

      assert {:ok, %{errors: [%{field: "email", code: "validation"} | _]}} =
               run(
                 """
                 mutation {
                   updateProfile(firstName: "Zakaria", email: "already-used@example.com") { id }
                 }
                 """,
                 context
               )
    end
  end

  describe "avatar mutations" do
    test "uploads, exposes, and removes the current user's avatar", %{
      user: user,
      context: context
    } do
      assert {:ok, %{data: %{"requestAvatarUpload" => ticket}}} =
               run(
                 """
                 mutation {
                   requestAvatarUpload(contentType: "image/jpeg", byteSize: 4000) {
                     url headers { name value } photo { id status kind }
                   }
                 }
                 """,
                 context
               )

      assert ticket["photo"]["kind"] == "avatar"
      attachment_id = String.to_integer(ticket["photo"]["id"])
      attachment = Blastek.Repo.get!(Blastek.Media.Attachment, attachment_id)
      :ok = Storage.put(attachment.key, jpeg(), "image/jpeg")

      assert {:ok, %{data: %{"finalizeAvatarUpload" => %{"status" => "ready"}}}} =
               run(
                 ~s|mutation { finalizeAvatarUpload(id: "#{attachment_id}") { status } }|,
                 context
               )

      assert {:ok, %{data: %{"me" => %{"avatarUrl" => avatar_url}}}} =
               run("{ me { avatarUrl } }", context)

      assert avatar_url == Media.avatar_url(user.id)

      assert {:ok, %{data: %{"deleteAvatar" => true}}} =
               run("mutation { deleteAvatar }", context)

      assert Media.avatar_url(user.id) == nil
    end

    test "requires authentication" do
      assert {:ok, %{errors: [%{message: message} | _]}} =
               run(
                 ~s|mutation { requestAvatarUpload(contentType: "image/jpeg") { url } }|,
                 %{}
               )

      assert message =~ "signed in"
    end
  end
end
