defmodule Mister.StandingsParserTest do
  use ExUnit.Case, async: true

  alias Mister.StandingsParser

  @standings_html """
  <div class="panels-standings">
    <ul class="player-list">
      <li>
        <div class="player-row">
          <a class="btn btn-sw-link user" href="users/15458034/curas-tocones" data-event="select_gameuser">
            <div class="position">1</div>
            <div class="user-avatar"><span>CT</span></div>
            <div class="info">
              <div class="name ">Curas Tocones</div>
              <div class="played">18 jugadores · € 90.188.000</div>
            </div>
            <div class="points">224 <span>Pts</span></div>
          </a>
        </div>
      </li>
      <li>
        <div class="player-row">
          <a class="btn btn-sw-link user" href="users/14655807/aitor-sagasta">
            <div class="position">2</div>
            <div class="info">
              <div class="name">Aitor Sagasta</div>
              <div class="played">12 jugadores · € 82.924.000</div>
            </div>
            <div class="points">198 Pts</div>
          </a>
        </div>
      </li>
    </ul>
  </div>
  """

  test "parsea el marcado actual (href users/<id>/<slug>)" do
    assert [first, second] = StandingsParser.parse(@standings_html)

    assert first.user_id == "15458034"
    assert first.slug == "curas-tocones"
    assert first.name == "Curas Tocones"
    assert first.points == 224.0
    assert first.squad_value == 90_188_000

    assert second.user_id == "14655807"
    assert second.slug == "aitor-sagasta"
    assert second.squad_value == 82_924_000
  end

  test "deduplica participantes repetidos" do
    duplicated = @standings_html <> @standings_html
    assert length(StandingsParser.parse(duplicated)) == 2
  end

  test "devuelve lista vacía si no hay clasificación" do
    assert StandingsParser.parse("<div>nada</div>") == []
  end
end
