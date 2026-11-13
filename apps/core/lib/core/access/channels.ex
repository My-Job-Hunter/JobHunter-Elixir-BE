defmodule Core.Access.Channels do
  @moduledoc """
  *New address* on an email channel (AQ-09 §4), **pure**, decided on the
  caller's reach to the channel's customer (`Core.Access`): the system
  admin, the customer's team leads and the customer themselves may; staff
  only when they own one of the profiles the channel serves
  (`owner_user_ids`, filled by `Core.Customers.Channels`); anyone who
  can't see the customer finds nothing.
  """

  alias Data.Scope

  @words "Only the customer's leads and owners can change it."

  @doc "The words a member who owns none of its profiles is refused with."
  def words, do: @words

  @doc "`:ok`, or the refusal."
  @spec renew_address(Scope.t(), map(), term()) :: :ok | {:error, term()}
  def renew_address(_scope, _channel, :none), do: {:error, :not_found}

  def renew_address(scope, channel, {:staff, :member}) do
    if Scope.user_id(scope) in Map.get(channel, :owner_user_ids, []),
      do: :ok,
      else: {:error, {:forbidden, @words}}
  end

  def renew_address(_scope, _channel, _admin_lead_or_self), do: :ok
end
