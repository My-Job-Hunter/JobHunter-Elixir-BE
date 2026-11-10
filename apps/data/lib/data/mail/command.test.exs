defmodule Data.Mail.CommandTest do
  use ExUnit.Case, async: true

  alias Data.Mail.Command

  test "builds from atoms or strings, and says what is missing" do
    assert {:ok, %Command{kind: :invitation, subject_id: "i1", secret: nil, options: %{}}} =
             Command.new(%{"kind" => "invitation", "subject_id" => "i1"})

    assert {:error, message} = Command.new(%{kind: :invitation})
    assert message =~ "subject_id"
    assert {:error, _message} = Command.new("not a map")
    assert_raise ArgumentError, fn -> Command.new!(%{}) end
  end

  test "round-trips through job args; an unknown kind is refused rather than made an atom" do
    command =
      Command.new!(%{
        kind: :password_reset,
        subject_id: "t1",
        secret: "s",
        options: %{reason: "x"}
      })

    args = Command.to_job_args(command)

    assert args == %{
             "kind" => "password_reset",
             "subject_id" => "t1",
             "secret" => "s",
             "options" => %{"reason" => "x"}
           }

    assert {:ok, back} = Command.from_job_args(args)
    assert back.kind == :password_reset and back.secret == "s"

    assert {:error, _message} =
             Command.from_job_args(%{
               "kind" => "never_heard_of_this_kind_xyz",
               "subject_id" => "t1"
             })
  end
end
