defmodule Mister.Report.Input do
  @moduledoc """
  Datos ya calculados que entran en `Mister.Report.build/1`.

  Nombrar la entrada convierte el contrato del informe (antes un mapa suelto
  que el worker y los tests tenían que conocer) en una interfaz explícita.
  """

  @enforce_keys [:budget]
  defstruct budget: nil,
            buy_candidates: [],
            valuations: %{},
            clause_targets: [],
            lineup: %{},
            squad_summary: %{},
            my_squad: []

  @type t :: %__MODULE__{
          budget: map(),
          buy_candidates: [Mister.PlayerRow.t()],
          valuations: %{optional(integer()) => map()},
          clause_targets: [map()],
          lineup: map(),
          squad_summary: map(),
          my_squad: [Mister.PlayerRow.t()]
        }
end
