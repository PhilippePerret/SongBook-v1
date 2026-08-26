# frozen_string_literal: true

require_relative "../spec_helper"
require "tablator_assistant"

# `matrix_to_tokens`/`matrix_from_tokens` : doigtés (main droite p/i/m/a/c + main
# gauche chiffre) et barres de mesure (Phil, 2026-08-26), notamment le cas central —
# une barre borne la durée de la note qui la précède, plus jamais `width` (arbitraire).
RSpec.describe "TablatorAssistant : grille (doigtés + barres)" do
  def cell(kase, rh: nil, lh: nil)
    TablatorAssistant::Cell.new(kase, rh, lh)
  end

  def matrix(width, notes = {})
    m = Array.new(6) { Array.new(width) }
    notes.each { |(string, col), c| m[string - 1][col] = c }
    m
  end

  describe ".matrix_to_tokens" do
    it "note simple, sans doigté ni barre : aucun suffixe" do
      tokens = TablatorAssistant.matrix_to_tokens(matrix(4, [5, 0] => cell(0)), "croche")
      expect(tokens).to eq(["50/2"])
    end

    it "doigté main droite seul" do
      tokens = TablatorAssistant.matrix_to_tokens(matrix(4, [5, 0] => cell(0, rh: "p")), "croche")
      expect(tokens.first).to end_with("-p")
    end

    it "doigté main gauche seul" do
      tokens = TablatorAssistant.matrix_to_tokens(matrix(4, [5, 0] => cell(0, lh: "2")), "croche")
      expect(tokens.first).to end_with("-2")
    end

    it "les deux combinés, main droite d'abord (ordre de saisie)" do
      tokens = TablatorAssistant.matrix_to_tokens(matrix(4, [5, 0] => cell(0, rh: "p", lh: "2")), "croche")
      expect(tokens.first).to end_with("-p2")
    end

    it "une barre après la dernière note borne SA durée (bug 2026-08-26 : bornait sur `width`, arbitraire)" do
      m = matrix(6, [5, 0] => cell(0))
      sans_barre = TablatorAssistant.matrix_to_tokens(m, "croche")
      avec_barre = TablatorAssistant.matrix_to_tokens(m, "croche", bars: { 2 => "|." })

      expect(sans_barre).to eq(["50/2."]) # span jusqu'à width=6 (demi-pointée)
      expect(avec_barre).to eq(["50/4", "|."]) # span jusqu'à la barre (col 2 : noire)
      expect(sans_barre.first).not_to eq(avec_barre.first)
    end

    it "la barre RÉDUIT effectivement la durée par rapport à `width` (cas où ça diffère)" do
      m = matrix(8, [5, 0] => cell(0))
      sans_barre = TablatorAssistant.matrix_to_tokens(m, "croche")
      avec_barre = TablatorAssistant.matrix_to_tokens(m, "croche", bars: { 2 => "|." })

      expect(sans_barre.first).not_to eq(avec_barre.first)
      expect(avec_barre).to eq(["50/4", "|."])
    end

    it "une barre entre deux notes borne la première, pas la seconde" do
      m = matrix(6, [5, 0] => cell(0), [4, 4] => cell(2))
      tokens = TablatorAssistant.matrix_to_tokens(m, "croche", bars: { 2 => "|" })
      expect(tokens).to eq(["50/4", "|", "42/4"])
    end

    it "seulement des barres, aucune note : renvoyées telles quelles" do
      expect(TablatorAssistant.matrix_to_tokens(matrix(4), "croche", bars: { 1 => "|." })).to eq(["|."])
    end

    it "grille vide : liste vide" do
      expect(TablatorAssistant.matrix_to_tokens(matrix(4), "croche")).to eq([])
    end
  end

  describe ".matrix_from_tokens (aller-retour)" do
    it "reconstruit le doigté dans la Cell" do
      m, = TablatorAssistant.matrix_from_tokens(["60/4-p2"], 4, "croche")
      expect(m[5][0]).to eq(TablatorAssistant::Cell.new(0, "p", "2"))
    end

    it "reconnaît les 6 formes de barre et leur colonne" do
      _, bars = TablatorAssistant.matrix_from_tokens(["50/4", "|.", "62/4"], 6, "croche")
      expect(bars).to eq({ 2 => "|." })
    end

    it "aller-retour complet : matrix_to_tokens puis matrix_from_tokens redonne le même résultat" do
      original = matrix(6, [5, 0] => cell(0, rh: "i", lh: "3"))
      tokens = TablatorAssistant.matrix_to_tokens(original, "croche", bars: { 2 => "||" })
      rebuilt, bars = TablatorAssistant.matrix_from_tokens(tokens, 6, "croche")

      expect(rebuilt[4][0]).to eq(cell(0, rh: "i", lh: "3"))
      expect(bars).to eq({ 2 => "||" })
    end
  end
end
