defmodule Mister.PlayerRowParserTest do
  use ExUnit.Case, async: true

  alias Mister.PlayerRowParser

  @market_li """
  <ul>
    <li data-position="4" data-price="16930000" data-owner="14655780">
      <div class="player-row">
        <a class="btn btn-sw-link player" href="players/62904/yan-diomande">
          <div class="icons">
            <img class='team-logo' width='20' height='20' src='https://cdn-mister.mundodeportivo.com/file/cdn-common/teams/15.png?version=x' loading='lazy'>
            <div class='player-position ' data-position='4'></div>
            <div class="points">8</div>
          </div>
          <div class="player-avatar" data-id_player="62904"><img src="/players/62904.png"></div>
          <div class="info">
            <div class="name">Y. Diomande</div>
            <div class="underName"><span class="euro">€</span>16.930.000 <span class="value-arrow red">↓</span></div>
          </div>
        </a>
      </div>
    </li>
  </ul>
  """

  test "extrae escudo, posición, id y precio de la fila" do
    assert [row] = PlayerRowParser.parse_all(@market_li)

    assert row.player_id == 62_904
    assert row.name == "Y. Diomande"
    assert row.position == 4
    assert row.price == 16_930_000
    assert row.trend == :down

    assert row.team_logo_url ==
             "https://cdn-mister.mundodeportivo.com/file/cdn-common/teams/15.png?version=x"
  end

  test "sin escudo deja team_logo_url a nil" do
    html =
      ~s(<li data-player-id="1" data-position="1" data-price="1000000"><div class="name">Portero</div></li>)

    assert [row] = PlayerRowParser.parse_all(html)
    assert row.team_logo_url == nil
  end
end
