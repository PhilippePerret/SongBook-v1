# frozen_string_literal: true

require_relative "../spec_helper"
require "dsl_parser"

# Tests des outils
RSpec.describe "lecture des paroles et accords (.lyr)" do
  describe "reconnaître un accord dans le texte" do
    it "Lire un accord simple sur une syllabe" do
      segments = DSLParser.parse_line("/A:Bon")
      expect(segments.first.chord).to eq("A")
      expect(segments.first.text).to eq("Bon")
    end

    it "Lire un accord avec sa case précise" do
      segments = DSLParser.parse_line("/Bb-6:jour")
      expect(segments.first.chord).to eq("Bb")
      expect(segments.first.fret).to eq("6")
    end

    it "reconnaître un accord même avec une case écrite bizarrement (pas juste un chiffre)" do
      segments = DSLParser.parse_line("/g2-0C:la")
      expect(segments.first.chord).to eq("G2")
      expect(segments.first.fret).to eq("0C")
    end

    it "reconnaître un accord avec quinte augmentée (+)" do
      segments = DSLParser.parse_line("/d75+:hop")
      expect(segments.first.chord).to eq("D75+")
    end

    it "Mettre en majuscule la première lettre d'un accord tapé en minuscule" do
      expect(DSLParser.normalize_chord("am7")).to eq("Am7")
    end

    it "Forcer la basse d'un accord entre crochets en MINUSCULE (règle inverse de la fondamentale)" do
      expect(DSLParser.normalize_chord("a[C]m7")).to eq("A[c]m7")
    end

    it "basse seule entre crochets : minuscule forcée, même tapée en majuscule" do
      expect(DSLParser.normalize_chord("[FD]")).to eq("[fd]")
    end

    it "Remplacer un accord seul sans mot par un espace (alignement)" do
      segments = DSLParser.parse_line("/A:_")
      expect(segments.first.text).to eq("   ")
    end
  end

  describe "découper le fichier en morceaux" do
    it "Séparer les informations du début (frontmatter) du reste des paroles" do
      song = DSLParser.parse("---\ntitle: Test\n---\nBonjour\n")
      expect(song.meta["title"]).to eq("Test")
      expect(song.blocks.first.lines.first.segments.first.text).to eq("Bonjour")
    end

    it "Lire les indications entre accolades au début d'un morceau" do
      song = DSLParser.parse("{tabla: intro.tab; shrink: true;}\nParoles\n")
      expect(song.blocks.first.directives).to eq({ tabla: "intro.tab", shrink: "true" })
    end

    it "Savoir que deux morceaux vont côte à côte (//)" do
      song = DSLParser.parse("Premier\n\n//\n\nDeuxième\n")
      expect(song.blocks[1].paired_with_previous).to be true
    end
  end
end
