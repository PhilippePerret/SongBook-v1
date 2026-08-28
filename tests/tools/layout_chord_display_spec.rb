# frozen_string_literal: true

require_relative "../spec_helper"
require "layout"

# Rendu ("gravure") des accords : la fondamentale garde les lettres A-G (`convert_note_symbol`),
# mais la basse entre crochets (`A[c]m7`, `[fd]` seule) suit une règle DIFFÉRENTE (Phil,
# 2026-08-28) : toujours en solfège ITALIEN (do/ré/mi/fa/sol/la/si), toujours en minuscule.
RSpec.describe "Layout : affichage des accords (basse en solfège italien)" do
  describe ".italian_bass_symbol" do
    it "convertit chaque lettre en syllabe italienne" do
      expect(Layout.italian_bass_symbol("a")).to eq("la")
      expect(Layout.italian_bass_symbol("b")).to eq("si")
      expect(Layout.italian_bass_symbol("c")).to eq("do")
      expect(Layout.italian_bass_symbol("d")).to eq("ré")
      expect(Layout.italian_bass_symbol("e")).to eq("mi")
      expect(Layout.italian_bass_symbol("f")).to eq("fa")
      expect(Layout.italian_bass_symbol("g")).to eq("sol")
    end

    it "dièse (\"d\" en 2e position) -> ♯ APRÈS la syllabe" do
      expect(Layout.italian_bass_symbol("fd")).to eq("fa♯")
    end

    it "bémol (\"b\" en 2e position) -> ♭ après la syllabe" do
      expect(Layout.italian_bass_symbol("bb")).to eq("si♭") # "bb" = si BÉMOL
    end

    it "toujours en minuscule, même si la fondamentale de la basse est en majuscule" do
      # Le stockage (`DSLParser.normalize_chord`) garantit déjà l'alteration ("d"/"b")
      # en minuscule — seule la lettre racine (1re position) est testée ici en majuscule.
      expect(Layout.italian_bass_symbol("F")).to eq("fa")
      expect(Layout.italian_bass_symbol("Fd")).to eq("fa♯")
    end
  end

  describe ".display_chord (basse embarquée ou seule)" do
    it "basse seule entre crochets -> \"/<syllabe italienne>\"" do
      expect(Layout.display_chord("[fd]")).to eq("/fa♯")
    end

    it "basse embarquée dans un accord : fondamentale en lettre, basse en italien" do
      expect(Layout.display_chord("Am7[c]")).to eq("Am7/do")
    end

    it "fondamentale seule (sans basse) : comportement inchangé (lettres A-G)" do
      expect(Layout.display_chord("Am7")).to eq("Am7")
      expect(Layout.display_chord("Fd")).to eq("F♯")
    end
  end
end
