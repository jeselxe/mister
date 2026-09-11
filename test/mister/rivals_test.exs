defmodule Mister.RivalsTest do
  use ExUnit.Case, async: true

  alias Mister.{ClauseDetector, Rivals}

  test "normaliza una fila de team_now adjuntando el propietario" do
    player = %{
      "id" => 1,
      "name" => "Rival",
      "avg" => 5.0,
      "clause" => %{"value" => 5_000_000},
      "id_uc" => 99
    }

    assert %{"player" => %{"owner" => %{"id" => 99}}} = Rivals.normalize(player, "7")
  end

  test "usa el id de la petición si la fila no trae id_uc" do
    assert %{"player" => %{"owner" => %{"id" => 7}}} = Rivals.normalize(%{"id" => 2}, "7")
  end

  test "adjunta el nombre del dueño desde la clasificación" do
    player = %{"id" => 1, "avg" => 5.0, "clause" => %{"value" => 5_000_000}, "id_uc" => 99}

    assert %{"player" => %{"owner" => %{"id" => 99, "name" => "Aitor"}}} =
             Rivals.normalize(player, "7", "Aitor")
  end

  test "el jugador normalizado lo acepta el detector de clausulazos" do
    player = %{
      "id" => 1,
      "name" => "Rival",
      "avg" => 5.0,
      "clause" => %{"value" => 5_000_000},
      "id_uc" => 99
    }

    assert [%{player_id: 1, clause_price: 5_000_000}] =
             ClauseDetector.find_opportunities([Rivals.normalize(player, "7")], 10_000_000)
  end
end
