defmodule Mister.FormatTest do
  use ExUnit.Case, async: true

  alias Mister.Format

  test "number/1 separa los miles con punto" do
    assert Format.number(8_664_600) == "8.664.600"
    assert Format.number(1_000) == "1.000"
    assert Format.number(999) == "999"
    assert Format.number(nil) == ""
  end

  test "money/1 añade el símbolo de euro" do
    assert Format.money(8_664_600) == "8.664.600 €"
    assert Format.money(nil) == "?"
  end
end
