defmodule Blastek.Notifications.Format do
  @moduledoc """
  Dates and times as a person reads them, per locale (E6-T2 / F0.10).

  Kept out of `Templates` so the copy never does calendar arithmetic: a template
  receives "samedi 2 août à 14:30" and interpolates it.

  Morocco is `Africa/Casablanca` throughout — F0.10 fixes the timezone for
  Phase 0 and the venue column exists for when that stops being true. Because it
  is fixed, appointment times need no conversion at all: `appointments.date` and
  `start_min` are already local wall-clock, which is what a customer is being
  told to turn up at.

  Minutes may exceed 1440 for a shift running past midnight (00:30 is 1470), so
  formatting wraps and says so rather than printing "24:30".
  """

  @timezone "Africa/Casablanca"

  @days %{
    "fr" => ~w(dimanche lundi mardi mercredi jeudi vendredi samedi),
    "ar" => ~w(الأحد الاثنين الثلاثاء الأربعاء الخميس الجمعة السبت),
    "en" => ~w(Sunday Monday Tuesday Wednesday Thursday Friday Saturday)
  }

  @months %{
    "fr" =>
      ~w(janvier février mars avril mai juin juillet août septembre octobre novembre décembre),
    "ar" => ~w(يناير فبراير مارس أبريل ماي يونيو يوليوز غشت شتنبر أكتوبر نونبر دجنبر),
    "en" =>
      ~w(January February March April May June July August September October November December)
  }

  def timezone, do: @timezone

  @doc ~S"""
  A date and a start minute as one phrase: "samedi 2 août à 14:30".

  A time past midnight belongs to the next morning, so the *date* advances with
  it — telling somebody to come "Friday at 00:30" when the salon means Saturday
  is how a customer arrives twenty-four hours late.
  """
  def date_time(%Date{} = date, start_min, locale) do
    {date, minute} = wrap(date, start_min)
    "#{long_date(date, locale)} #{at(locale)}#{time(minute)}"
  end

  @doc "Just the clock time, wrapping past midnight."
  def time(minute) when is_integer(minute) do
    minute = Integer.mod(minute, 1440)
    "#{pad(div(minute, 60))}:#{pad(rem(minute, 60))}"
  end

  @doc ~S"""
  A date without the time: "samedi 2 août".
  """
  def long_date(%Date{} = date, locale) do
    locale = locale(locale)
    day_name = @days |> Map.fetch!(locale) |> Enum.at(Date.day_of_week(date, :sunday) - 1)
    month = @months |> Map.fetch!(locale) |> Enum.at(date.month - 1)

    "#{day_name} #{date.day} #{month}"
  end

  @doc """
  The date and minute a start time really falls on.

  `{date, minute}` with the minute inside a day. 1470 on Friday is 00:30 on
  Saturday.
  """
  def wrap(%Date{} = date, start_min) do
    {Date.add(date, div(start_min, 1440)), Integer.mod(start_min, 1440)}
  end

  @doc """
  When an appointment starts, as a `NaiveDateTime` in the venue's local time.

  Used for scheduling: a reminder is "24 hours before this", and "this" has to
  be a point in time rather than a date and a column of minutes.
  """
  def starts_at(%Date{} = date, start_min) do
    {date, minute} = wrap(date, start_min)
    NaiveDateTime.new!(date, Time.new!(div(minute, 60), rem(minute, 60), 0))
  end

  defp at("fr"), do: "à "
  defp at("ar"), do: "على "
  defp at(_), do: "at "

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp locale(locale) when is_map_key(@days, locale), do: locale
  defp locale(_), do: "fr"
end
