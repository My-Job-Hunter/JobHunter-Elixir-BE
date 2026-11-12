defmodule Core.Contacts.Match do
  @moduledoc """
  The match check (AQ-06 §6, QP6-4), **pure**: what is known about the
  contacts that might be the one typed or captured, in; the answer out.

  | When | Answer |
  |---|---|
  | a handle matches exactly (the same email, LinkedIn or Upwork, normalised) | `exact`: that contact; nothing new is made |
  | the same name and company — normalised, or trigram ≥ 0.8 on the name with the same company; with no company, the same normalised name | `possible`: "Is this *Mei Chen* at *Juniper Edge*?" |
  | neither | `new` |

  A merged contact answers as its survivor (`Data.Contacts.by_handles/2`
  resolves it before this module sees it).
  """

  @threshold 0.8

  @type answer :: %{answer: :exact | :possible | :new, contact: map() | nil, candidates: [map()]}

  @doc "The trigram score at or above which a name with the same company is a possible match."
  def threshold, do: @threshold

  @doc """
  Decides. `exact` are the contacts holding one of the handles; `similar`
  the `{contact, score}` of names like `name` (normalised); `company_id`
  the company typed, or `nil`.
  """
  @spec decide([map()], [{map(), float()}], String.t(), binary() | nil) :: answer()
  def decide([first | rest], _similar, _name, _company_id),
    do: %{answer: :exact, contact: first, candidates: rest}

  def decide([], similar, name, company_id) do
    case Enum.filter(similar, &possible?(&1, name, company_id)) do
      [] ->
        %{answer: :new, contact: nil, candidates: []}

      found ->
        candidates =
          found
          |> Enum.sort_by(fn {c, score} -> {-score, c.name_normalized, c.id} end)
          |> Enum.map(&elem(&1, 0))

        %{answer: :possible, contact: nil, candidates: candidates}
    end
  end

  defp possible?({contact, _score}, name, nil), do: contact.name_normalized == name

  defp possible?({contact, score}, name, company_id) do
    contact.company_id == company_id and (contact.name_normalized == name or score >= @threshold)
  end
end
