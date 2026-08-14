defmodule Blastek.BlocksTest do
  @moduledoc """
  Time off, breaks and one-off blocks, and what they do to availability
  (E9-T1, E9-T3 / F0.7).

  Every test here asserts against `Salon.availability/4` rather than against
  `Blocks.windows/3`, because a block that is stored perfectly and not
  subtracted is a slot offered for a stylist who is on holiday — and that is
  the only failure a customer ever experiences.
  """
  use Blastek.DataCase, async: true

  import Blastek.Fixtures

  alias Blastek.Salon
  alias Blastek.Salon.Blocks

  setup do
    v = venue_fixture("Blocks Salon #{System.unique_integer([:positive])}")
    # The fixture works 09:00–18:00 with a 60-minute service.
    # Tomorrow, so today's notice period cannot eat the morning slots. The
    # fixture works every day, so any date is a working one.
    %{v: v, date: Date.add(Blastek.Clock.today(), 1)}
  end

  defp slots(v, date) do
    {:ok, %{slots: slots}} = Salon.availability(v.venue.id, [v.service.id], "any", date)
    Enum.map(slots, & &1.start_min)
  end

  describe "a break" do
    test "removes the slots it covers and leaves the rest", ctx do
      before = slots(ctx.v, ctx.date)
      assert 720 in before, "12:00 should be bookable before the break exists"

      {:ok, _} =
        Blocks.create(ctx.v.venue.id, %{
          staff_id: ctx.v.staff.id,
          kind: "break",
          date: ctx.date,
          start_min: 720,
          end_min: 840
        })

      after_break = slots(ctx.v, ctx.date)

      # A 60-minute service cannot start at 12:00 or overlap the break, but the
      # morning and the afternoon are untouched.
      refute 720 in after_break
      refute 780 in after_break
      assert 540 in after_break
      assert 840 in after_break
    end

    test "only applies to the day it names", ctx do
      {:ok, _} =
        Blocks.create(ctx.v.venue.id, %{
          staff_id: ctx.v.staff.id,
          kind: "break",
          date: ctx.date,
          start_min: 720,
          end_min: 840
        })

      assert 720 in slots(ctx.v, Date.add(ctx.date, 1))
    end
  end

  describe "a weekly break" do
    test "repeats on that weekday without a row per week", ctx do
      {:ok, block} =
        Blocks.create(ctx.v.venue.id, %{
          staff_id: ctx.v.staff.id,
          kind: "break",
          date: ctx.date,
          start_min: 720,
          end_min: 840,
          weekly: true
        })

      # One row, derived weekday, and it bites seven and fourteen days later.
      assert block.weekly
      assert block.weekday == Date.day_of_week(ctx.date, :sunday) - 1

      for weeks <- [0, 1, 2] do
        day = Date.add(ctx.date, weeks * 7)
        refute 720 in slots(ctx.v, day), "the weekly break should apply #{weeks} week(s) on"
      end
    end

    test "does not apply to other weekdays", ctx do
      {:ok, _} =
        Blocks.create(ctx.v.venue.id, %{
          staff_id: ctx.v.staff.id,
          kind: "break",
          date: ctx.date,
          start_min: 720,
          end_min: 840,
          weekly: true
        })

      assert 720 in slots(ctx.v, Date.add(ctx.date, 1))
    end

    test "does not apply before the week it starts", ctx do
      start = Date.add(ctx.date, 7)

      {:ok, _} =
        Blocks.create(ctx.v.venue.id, %{
          staff_id: ctx.v.staff.id,
          kind: "break",
          date: start,
          start_min: 720,
          end_min: 840,
          weekly: true
        })

      # "Every Friday from next week" must not retroactively clear this Friday.
      assert 720 in slots(ctx.v, ctx.date)
      refute 720 in slots(ctx.v, start)
    end
  end

  describe "time off" do
    test "takes the whole day, whatever the shift is", ctx do
      {:ok, block} =
        Blocks.create(ctx.v.venue.id, %{
          staff_id: ctx.v.staff.id,
          kind: "time_off",
          date: ctx.date
        })

      # Minutes are meaningless for a whole-day absence and are cleared, so a
      # caller cannot half-configure one.
      assert block.start_min == nil
      assert block.end_min == nil
      assert slots(ctx.v, ctx.date) == []
    end

    test "covers every day of a range, inclusive", ctx do
      last = Date.add(ctx.date, 3)

      {:ok, _} =
        Blocks.create(ctx.v.venue.id, %{
          staff_id: ctx.v.staff.id,
          kind: "time_off",
          date: ctx.date,
          end_date: last
        })

      for day <- Date.range(ctx.date, last) do
        assert slots(ctx.v, day) == [], "#{day} is inside the holiday"
      end

      refute slots(ctx.v, Date.add(last, 1)) == []
    end
  end

  describe "one staff member's block is not another's" do
    test "a colleague keeps their slots", ctx do
      other = staff_fixture(ctx.v.venue.id, "Second Stylist", [ctx.v.service.id])

      {:ok, _} =
        Blocks.create(ctx.v.venue.id, %{
          staff_id: ctx.v.staff.id,
          kind: "time_off",
          date: ctx.date
        })

      # "Any professional" must still find the colleague — a holiday is not a
      # closure, and treating it as one costs the salon a booking.
      assert 540 in slots(ctx.v, ctx.date)

      {:ok, %{slots: theirs}} =
        Salon.availability(ctx.v.venue.id, [ctx.v.service.id], to_string(other.id), ctx.date)

      refute theirs == []

      {:ok, %{slots: mine}} =
        Salon.availability(
          ctx.v.venue.id,
          [ctx.v.service.id],
          to_string(ctx.v.staff.id),
          ctx.date
        )

      assert mine == []
    end
  end

  describe "overlapping blocks" do
    test "are merged on read rather than tested one by one", _ctx do
      assert Blocks.merge([{540, 600}, {580, 660}, {900, 960}]) == [{540, 660}, {900, 960}]
      # Touching, not overlapping: 09:00–10:00 and 10:00–11:00 are one span.
      assert Blocks.merge([{540, 600}, {600, 660}]) == [{540, 660}]
      assert Blocks.merge([]) == []
    end
  end

  describe "conflicts" do
    test "a proposed block reports the appointments it would sit on", ctx do
      {:ok, %{slots: [%{start_min: start_min} | _]}} =
        Salon.availability(ctx.v.venue.id, [ctx.v.service.id], "any", ctx.date)

      {:ok, _} =
        Salon.book(ctx.v.venue.id, %{
          client_id: ctx.v.client.id,
          service_ids: [ctx.v.service.id],
          staff_id: "any",
          date: ctx.date,
          start_min: start_min
        })

      conflicts =
        Blocks.conflicts(ctx.v.venue.id, %{
          staff_id: ctx.v.staff.id,
          kind: "time_off",
          date: ctx.date
        })

      # F0.7: never silent. The owner is shown what they are about to break.
      assert length(conflicts) == 1
      assert hd(conflicts).start_min == start_min
    end

    test "and reports none when the day is empty", ctx do
      assert Blocks.conflicts(ctx.v.venue.id, %{
               staff_id: ctx.v.staff.id,
               kind: "time_off",
               date: ctx.date
             }) == []
    end

    test "a colleague's appointments are not reported", ctx do
      other = staff_fixture(ctx.v.venue.id, "Third Stylist", [ctx.v.service.id])

      {:ok, %{slots: [%{start_min: start_min} | _]}} =
        Salon.availability(ctx.v.venue.id, [ctx.v.service.id], to_string(other.id), ctx.date)

      {:ok, _} =
        Salon.book(ctx.v.venue.id, %{
          client_id: ctx.v.client.id,
          service_ids: [ctx.v.service.id],
          staff_id: to_string(other.id),
          date: ctx.date,
          start_min: start_min
        })

      assert Blocks.conflicts(ctx.v.venue.id, %{
               staff_id: ctx.v.staff.id,
               kind: "time_off",
               date: ctx.date
             }) == []
    end
  end

  describe "deleting a block" do
    test "gives the time back to availability", ctx do
      {:ok, block} =
        Blocks.create(ctx.v.venue.id, %{
          staff_id: ctx.v.staff.id,
          kind: "break",
          date: ctx.date,
          start_min: 720,
          end_min: 840
        })

      refute 720 in slots(ctx.v, ctx.date)

      assert {:ok, _} = Blocks.delete(ctx.v.venue.id, block.id)
      assert 720 in slots(ctx.v, ctx.date)
    end

    test "another venue cannot delete it", ctx do
      {:ok, block} =
        Blocks.create(ctx.v.venue.id, %{
          staff_id: ctx.v.staff.id,
          kind: "break",
          date: ctx.date,
          start_min: 720,
          end_min: 840
        })

      stranger = venue_fixture("Nosy #{System.unique_integer([:positive])}")

      assert {:error, :not_found} = Blocks.delete(stranger.venue.id, block.id)
      # And it is still doing its job.
      refute 720 in slots(ctx.v, ctx.date)
    end
  end

  describe "validation" do
    test "a range that ends before it starts is refused", ctx do
      assert {:error, changeset} =
               Blocks.create(ctx.v.venue.id, %{
                 staff_id: ctx.v.staff.id,
                 kind: "break",
                 date: ctx.date,
                 start_min: 840,
                 end_min: 720
               })

      refute changeset.valid?
    end

    test "a break with no times is refused rather than silently blocking nothing", ctx do
      assert {:error, changeset} =
               Blocks.create(ctx.v.venue.id, %{
                 staff_id: ctx.v.staff.id,
                 kind: "break",
                 date: ctx.date
               })

      refute changeset.valid?
    end

    test "another venue's staff cannot be blocked", ctx do
      stranger = venue_fixture("Stranger #{System.unique_integer([:positive])}")

      # The foreign key proves the staff member exists; only this proves they
      # work here. Without the check the row inserts, sits across a tenant
      # boundary, and blocks nobody — the quietest possible kind of wrong.
      assert {:error, changeset} =
               Blocks.create(ctx.v.venue.id, %{
                 staff_id: stranger.staff.id,
                 kind: "time_off",
                 date: ctx.date
               })

      assert "does not work at this venue" in errors_on(changeset).staff_id

      # And the stranger's own availability is untouched.
      {:ok, %{slots: theirs}} =
        Salon.availability(
          stranger.venue.id,
          [stranger.service.id],
          "any",
          ctx.date
        )

      refute theirs == []
    end
  end

  describe "a named staff member is still checked for eligibility" do
    test "availability offers nothing for somebody who does not perform the service", ctx do
      # A second stylist who performs *nothing*. Naming a staff member used to
      # skip the eligibility filter entirely, so availability answered for the
      # whole shift and `book/2` accepted it — a colourist booked for a massage
      # by anyone willing to post a staff id.
      other = staff_fixture(ctx.v.venue.id, "Unqualified", [])

      {:ok, %{slots: theirs}} =
        Salon.availability(ctx.v.venue.id, [ctx.v.service.id], to_string(other.id), ctx.date)

      assert theirs == []
    end

    test "and booking them is refused rather than accepted", ctx do
      other = staff_fixture(ctx.v.venue.id, "Unqualified Two", [])

      assert {:error, _} =
               Salon.book(ctx.v.venue.id, %{
                 client_id: ctx.v.client.id,
                 service_ids: [ctx.v.service.id],
                 staff_id: to_string(other.id),
                 date: ctx.date,
                 start_min: 540
               })
    end

    test "while the qualified colleague is unaffected", ctx do
      {:ok, %{slots: mine}} =
        Salon.availability(
          ctx.v.venue.id,
          [ctx.v.service.id],
          to_string(ctx.v.staff.id),
          ctx.date
        )

      refute mine == []
    end

    test "a staff id that is not a number matches nobody rather than raising", ctx do
      assert {:ok, %{slots: []}} =
               Salon.availability(ctx.v.venue.id, [ctx.v.service.id], "not-an-id", ctx.date)
    end
  end

  describe "a block outside working hours" do
    test "is reported as such rather than moved", _ctx do
      # F0.7: blocks follow the clock, so a Ramadan template that moves the
      # working day leaves a midday break stranded. The owner is warned; the
      # block is not silently relocated.
      assert Blocks.outside_hours?({1200, 1500}, 720, 840)
      refute Blocks.outside_hours?({540, 1080}, 720, 840)
      refute Blocks.outside_hours?(nil, 720, 840)
    end
  end
end
