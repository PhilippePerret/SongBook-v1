# frozen_string_literal: true

require_relative "../spec_helper"
require_relative "../../tools/ChordDiagram/generate_chord_diagrams"

RSpec.describe "barré traversant le manche" do
  def main_span(tokens)
    GenerateChordDiagrams.decode(tokens)[:barres].first[:span].sort
  end

  it "traverse jusqu'à la corde 1 quand toutes les cordes plus aiguës sont frettées plus haut (Bm7-2A)" do
    expect(main_span("15/4 23/2 32/1 44/3 52/1 62/1")).to eq([0, 1, 2, 3, 4, 5])
  end

  it "ne traverse pas si une corde plus aiguë est à vide" do
    expect(main_span("10 23/2 32/1 44/3 52/1 62/1")).to eq([0, 1, 2, 3])
  end

  it "ne traverse pas un barré de 2 cordes" do
    expect(main_span("15/4 23/2 34/3 44/3 52/1 62/1")).to eq([0, 1])
  end
end
