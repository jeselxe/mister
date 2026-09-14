defmodule Mister.OfferAdviceTest do
  use ExUnit.Case, async: true

  alias Mister.OfferAdvice

  # Oferta base: puja = valor, sin tendencia ni precio de compra.
  defp offer(attrs),
    do: Map.merge(%{bid: 1_000_000, value: 1_000_000, trend_dir: :flat}, attrs)

  test "un titular nunca se vende" do
    assert {:deny, reason} = OfferAdvice.advise(offer(%{}), %{in_best_lineup: true})
    assert reason =~ "titular"
  end

  test "plusvalía fuerte con puja razonable: acepta" do
    assert {:accept, reason} =
             OfferAdvice.advise(offer(%{paid_price: 1_000_000, bid: 1_600_000}))

    assert reason =~ "plusvalía fuerte"
  end

  test "en alza con oferta baja: rechaza y aguanta" do
    assert {:deny, reason} =
             OfferAdvice.advise(offer(%{trend_dir: :up, bid: 950_000, paid_price: 1_000_000}))

    assert reason =~ "en alza"
  end

  test "en alza con buena oferta: acepta" do
    assert {:accept, reason} =
             OfferAdvice.advise(offer(%{trend_dir: :up, bid: 1_200_000, paid_price: 1_000_000}))

    assert reason =~ "plus excelente"
  end

  test "tendencia bajista con oferta razonable: acepta" do
    assert {:accept, reason} =
             OfferAdvice.advise(offer(%{trend_dir: :down, bid: 920_000, paid_price: 1_000_000}))

    assert reason =~ "bajista"
  end

  test "puja igual o por encima del valor: acepta" do
    assert {:accept, reason} = OfferAdvice.advise(offer(%{bid: 1_050_000}))
    assert reason =~ "valor de mercado"
  end

  test "por debajo del valor y a pérdidas: rechaza" do
    assert {:deny, reason} = OfferAdvice.advise(offer(%{bid: 800_000, paid_price: 1_000_000}))
    assert reason =~ "pérdidas"
  end

  test "cerca del valor y con beneficio: acepta" do
    assert {:accept, reason} = OfferAdvice.advise(offer(%{bid: 970_000, paid_price: 900_000}))
    assert reason =~ "beneficio"
  end

  test "plusvalía con puja por debajo del 90%: acepta por el beneficio" do
    assert {:accept, reason} =
             OfferAdvice.advise(offer(%{bid: 1_600_000, value: 2_000_000, paid_price: 1_000_000}))

    assert reason =~ "beneficio sólido"
  end

  test "sin margen claro: rechaza" do
    assert {:deny, reason} = OfferAdvice.advise(offer(%{bid: 600_000}))
    assert reason =~ "sin margen claro"
  end

  test "datos incompletos: rechaza" do
    assert {:deny, "datos incompletos"} = OfferAdvice.advise(%{value: 1_000_000})
    assert {:deny, "datos incompletos"} = OfferAdvice.advise(%{bid: 1_000_000, value: 0})
  end

  describe "profit/1" do
    test "calcula importe y porcentaje" do
      assert %{amount: 200_000, pct: 20} =
               OfferAdvice.profit(%{paid_price: 1_000_000, bid: 1_200_000})

      assert %{amount: -200_000, pct: -20} =
               OfferAdvice.profit(%{paid_price: 1_000_000, bid: 800_000})
    end

    test "sin precio de compra no hay beneficio" do
      assert OfferAdvice.profit(%{bid: 1_000_000}) == nil
      assert OfferAdvice.profit(%{paid_price: 0, bid: 1_000_000}) == nil
      assert OfferAdvice.profit(%{paid_price: 1_000_000, bid: nil}) == nil
    end
  end
end
