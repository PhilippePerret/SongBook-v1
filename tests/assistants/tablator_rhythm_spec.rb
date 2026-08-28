# frozen_string_literal: true

require_relative "../spec_helper"
require "tablator_assistant"

# Tests des assistants
RSpec.describe "rythme de l'assistant tablature" do
  def cell(kase)
    TablatorAssistant::Cell.new(kase, nil, nil)
  end

  describe "Un trou après une note allonge cette note" do
    it "un trou d'une case donne une noire (à partir d'une croche)" do
      matrix = Array.new(6) { Array.new(2) }
      matrix[4][0] = cell(0)
      expect(TablatorAssistant.matrix_to_tokens(matrix, "croche")).to eq(["50/4"])
    end

    it "deux cases de trou donnent une noire pointée" do
      matrix = Array.new(6) { Array.new(3) }
      matrix[4][0] = cell(0)
      expect(TablatorAssistant.matrix_to_tokens(matrix, "croche")).to eq(["50/4."])
    end
  end

  it "Un trou avant la première note devient un silence discret" do
    matrix = Array.new(6) { Array.new(4) }
    matrix[4][2] = cell(0)
    expect(TablatorAssistant.matrix_to_tokens(matrix, "croche")).to eq(["s4", "50/4"])
  end

  it "Une grille vide ne casse rien" do
    matrix = Array.new(6) { Array.new(4) }
    expect(TablatorAssistant.matrix_to_tokens(matrix, "croche")).to eq([])
  end

  it "Se relire soi-même sans rien perdre" do
    matrix = Array.new(6) { Array.new(4) }
    matrix[4][2] = cell(0)
    tokens = TablatorAssistant.matrix_to_tokens(matrix, "croche")
    reloaded, bars = TablatorAssistant.matrix_from_tokens(tokens, 4, "croche")
    expect(reloaded).to eq(matrix)
    expect(bars).to eq({})
  end

  it "Pousser tout ce qui suit vers la droite (notes)" do
    matrix = [[1, 2, 3, 4], [nil] * 4, [nil] * 4, [nil] * 4, [nil] * 4, [nil] * 4]
    TablatorAssistant.shift_right!(matrix, {}, {}, 1, 4)
    expect(matrix[0]).to eq([1, nil, 2, 3])
  end

  it "Pousser tout ce qui suit vers la gauche (notes)" do
    matrix = [[1, 2, 3, 4], [nil] * 4, [nil] * 4, [nil] * 4, [nil] * 4, [nil] * 4]
    TablatorAssistant.shift_left!(matrix, {}, {}, 1)
    expect(matrix[0]).to eq([1, 3, 4, nil])
  end

  it "Maj+→ décale AUSSI les barres et silences, pas seulement les notes (bug constaté, Phil)" do
    matrix = Array.new(6) { [nil] * 4 }
    bars = { 1 => "|", 2 => "||" }
    rests = { 3 => "r" }
    TablatorAssistant.shift_right!(matrix, bars, rests, 1, 4)
    expect(bars).to eq({ 2 => "|", 3 => "||" })
    expect(rests).to eq({})
  end

  it "Maj+← décale AUSSI les barres et silences, la colonne du curseur est écrasée" do
    matrix = Array.new(6) { [nil] * 4 }
    bars = { 1 => "|", 2 => "||" }
    rests = { 0 => "s" }
    TablatorAssistant.shift_left!(matrix, bars, rests, 1)
    expect(bars).to eq({ 1 => "||" })
    expect(rests).to eq({ 0 => "s" })
  end

  it "Accepter les chiffres tapés sans la touche Majuscule" do
    expect(TablatorAssistant::AZERTY_DIGITS["é"]).to eq("2")
    expect(TablatorAssistant::AZERTY_DIGITS["à"]).to eq("0")
  end

  it "Toujours écrire les cordes de mi en majuscule" do
    expect(TablatorAssistant::STRING_LABELS.first).to eq("E")
    expect(TablatorAssistant::STRING_LABELS.last).to eq("E")
  end
end
