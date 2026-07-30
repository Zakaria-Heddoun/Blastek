defmodule Blastek.Venues.Settings do
  @moduledoc """
  Typed validation for the venue settings blob (E5-T1 / F0.4).

  `venues.settings` is JSONB, which is the right storage for a bag of options
  that grows every epic — but it is the wrong place to be permissive. Without a
  schema, a typo writes a key nobody reads, a boolean arrives as `"false"` and
  is truthy forever, and a slot step of 7 minutes produces a booking grid no
  human can use.

  So the column stays schemaless and the **writes** are typed: everything goes
  through `change/2`, unknown keys are dropped rather than stored, and each
  known key is coerced and range-checked.

  Dropping unknown keys rather than rejecting them is deliberate. A client on an
  older build sending a since-renamed key should not have its whole settings
  save fail; the keys it does know about are still worth persisting.
  """

  @slot_steps [5, 10, 15, 20, 30, 60]

  # {key, type, default}. Adding a setting means adding a line here and nothing
  # else — which is the point of keeping this in one table.
  @schema [
    {"women_only", :boolean, false},
    {"amenities", {:list, :string}, []},
    {"slot_step_min", {:integer_in, @slot_steps}, 15},
    {"booking_lead_min", {:integer_range, 0, 10_080}, 0},
    {"booking_horizon_days", {:integer_range, 1, 365}, 90},
    {"cancellation_window_hours", {:integer_range, 0, 168}, 24},
    {"instant_confirmation", :boolean, true},
    {"locale", {:one_of, ["fr", "ar", "en"]}, "fr"},
    # Minutes before an appointment to remind the customer. Zero switches that
    # reminder off — a barber whose customers walk in anyway would rather send
    # nothing than train them to ignore messages. Capped at a week, because a
    # reminder further out than that is not a reminder.
    {"reminder_24h_min", {:integer_range, 0, 10_080}, 24 * 60},
    {"reminder_3h_min", {:integer_range, 0, 10_080}, 180}
  ]

  # Built once at compile time. Both read paths need the same lookup, and two
  # linear scans of the same list is one implementation too many.
  @by_key Map.new(@schema, fn {key, type, default} -> {key, {type, default}} end)

  def slot_steps, do: @slot_steps

  @doc "Every known key with its default — the shape a fresh venue starts with."
  def defaults, do: Map.new(@schema, fn {key, _type, default} -> {key, default} end)

  @doc """
  Merges `changes` into `current`, validating each known key.

  Returns `{:ok, settings}` or `{:error, message}`. Only keys present in
  `changes` are touched: a client sending one setting must not blank the rest.
  """
  def change(current, changes) when is_map(current) and is_map(changes) do
    changes = stringify_keys(changes)

    Enum.reduce_while(@schema, {:ok, current}, fn {key, type, _default}, {:ok, acc} ->
      case Map.fetch(changes, key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          case coerce(type, value) do
            {:ok, coerced} -> {:cont, {:ok, Map.put(acc, key, coerced)}}
            :error -> {:halt, {:error, message_for(key, type)}}
          end
      end
    end)
  end

  @doc """
  Reads a setting, falling back to its default.

  Always use this rather than reaching into the map: a venue created before a
  setting existed has no key for it, and every read site would otherwise need
  its own fallback.
  """
  def get(settings, key) when is_map(settings) do
    key = to_string(key)

    case {Map.fetch(settings, key), Map.fetch(@by_key, key)} do
      # Not a setting this module knows about: hand back whatever is stored.
      {{:ok, value}, :error} ->
        value

      {_, :error} ->
        nil

      {{:ok, value}, {:ok, {type, default}}} when not is_nil(value) ->
        # A value already in the database may predate a tightening of its type,
        # so reads repair rather than crash.
        case coerce(type, value) do
          {:ok, coerced} -> coerced
          :error -> default
        end

      {_, {:ok, {_type, default}}} ->
        default
    end
  end

  def get(_settings, key) do
    case Map.fetch(@by_key, to_string(key)) do
      {:ok, {_type, default}} -> default
      :error -> nil
    end
  end

  ## ---------- internals ----------

  defp coerce(:boolean, true), do: {:ok, true}
  defp coerce(:boolean, false), do: {:ok, false}
  defp coerce(:boolean, "true"), do: {:ok, true}
  defp coerce(:boolean, "false"), do: {:ok, false}
  defp coerce(:boolean, _), do: :error

  # A venue lists its parking and its wifi, not an essay. Bounded because the
  # column is JSONB with no schema to stop a client writing a megabyte into
  # every row it can authenticate against.
  @max_list_items 40
  @max_item_length 60

  defp coerce({:list, :string}, values) when is_list(values) do
    if Enum.all?(values, &is_binary/1) and length(values) <= @max_list_items do
      # Trimmed and de-duplicated: an amenities list is rendered as chips, and
      # "Parking" twice looks like a bug to the reader.
      {:ok,
       values
       |> Enum.map(&(&1 |> String.trim() |> String.slice(0, @max_item_length)))
       |> Enum.reject(&(&1 == ""))
       |> Enum.uniq()}
    else
      :error
    end
  end

  defp coerce({:list, :string}, _), do: :error

  defp coerce({:integer_in, allowed}, value) do
    with {:ok, int} <- to_integer(value),
         true <- int in allowed do
      {:ok, int}
    else
      _ -> :error
    end
  end

  defp coerce({:integer_range, low, high}, value) do
    with {:ok, int} <- to_integer(value),
         true <- int >= low and int <= high do
      {:ok, int}
    else
      _ -> :error
    end
  end

  defp coerce({:one_of, allowed}, value) when is_binary(value) do
    if value in allowed, do: {:ok, value}, else: :error
  end

  defp coerce({:one_of, _allowed}, _value), do: :error

  defp to_integer(value) when is_integer(value), do: {:ok, value}

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp to_integer(_), do: :error

  defp message_for("slot_step_min", _),
    do: "Slot step must be one of: #{Enum.join(@slot_steps, ", ")} minutes."

  defp message_for(key, {:integer_range, low, high}),
    do: "#{humanize(key)} must be between #{low} and #{high}."

  defp message_for(key, {:one_of, allowed}),
    do: "#{humanize(key)} must be one of: #{Enum.join(allowed, ", ")}."

  defp message_for(key, :boolean), do: "#{humanize(key)} must be true or false."

  defp message_for(key, {:list, :string}),
    do: "#{humanize(key)} must be a list of at most #{@max_list_items} short entries."

  defp message_for(key, _), do: "#{humanize(key)} is not valid."

  defp humanize(key), do: key |> String.replace("_", " ") |> String.capitalize()

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
