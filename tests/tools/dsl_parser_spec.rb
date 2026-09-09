# frozen_string_literal: true

require_relative "../spec_helper"
require "dsl_parser"
require "chord_diagrams"

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

    it "1re lettre de la basse entre crochets en MAJUSCULE, même règle que la fondamentale (issue #60)" do
      expect(DSLParser.normalize_chord("a[c]m7")).to eq("A[C]m7")
    end

    it "basse seule entre crochets : 1re lettre capitale, reste minuscule (issue #60)" do
      expect(DSLParser.normalize_chord("[fd]")).to eq("[Fd]")
      expect(DSLParser.normalize_chord("[FD]")).to eq("[Fd]")
    end

    it "Remplacer un accord seul sans mot par un espace (alignement)" do
      segments = DSLParser.parse_line("/A:_")
      expect(segments.first.text).to eq("   ")
    end
  end

  describe "\"/\" nu dans les paroles : TOUJOURS un séparateur d'accord/basse, jamais gravé dans les paroles (bug constaté, \"Nobody Home\"/\"En rouge et noir\" : le \"/\" de \"/F://C:\" se retrouvait à la fin du vers)" do
    it "2 accords collés (\"/F://C:\") : fusionnés en UN accord \"F/C\" (même mesure), jamais dans le texte, jamais 2 accords disjoints (régression constatée : purement supprimé, perdant le lien visuel)" do
      segments = DSLParser.parse_line("bone in /F://C:")
      expect(segments.map(&:text).join).not_to include("/")
      expect(segments.map(&:chord).compact).to eq(["F/C"])
    end

    it "2 accords collés, case sur le 2e SEULEMENT (\"/Bm://Am7-5:\", issue #81) : la case reste attachée à \"Am7\", jamais reportée sur \"Bm\"" do
      segments = DSLParser.parse_line("/Bm://Am7-5: refrain")
      expect(segments.first.chord).to eq("Bm/Am7")
      expect(ChordDiagrams.split_chord_frets(segments.first.chord, segments.first.fret)).to eq([["Bm", nil], ["Am7", "5"]])
    end

    it "2 accords collés, case sur le 1er SEULEMENT (\"/Am7-5://Bm:\") : la case reste attachée à \"Am7\", jamais reportée sur \"Bm\"" do
      segments = DSLParser.parse_line("/Am7-5://Bm: refrain")
      expect(ChordDiagrams.split_chord_frets(segments.first.chord, segments.first.fret)).to eq([["Am7", "5"], ["Bm", nil]])
    end

    it "accord collé EN PLEIN MILIEU d'un mot (\"Ni//Bm:kita\") : le mot reste intact" do
      segments = DSLParser.parse_line("Ni//Bm:kita")
      expect(segments.map(&:text).join).to eq("Nikita")
    end

    it "\"/\" échappé (\"\\/\") : reste un \"/\" littéral voulu par l'user" do
      segments = DSLParser.parse_line("rock\\/roll")
      expect(segments.first.text).to eq("rock/roll")
    end

    it "ligne sans aucun accord : le \"/\" nu disparaît quand même (règle absolue, jamais conditionnée à la présence d'un accord)" do
      segments = DSLParser.parse_line("juste du texte / avec un slash")
      expect(segments.first.text).not_to include("/")
    end
  end

  # 2026-09-07 (Phil : "[B] n'est pas obligatoirement une basse, ça évolue") : un
  # marqueur bracket SEUL ("[B]:") n'est PLUS automatiquement une basse — distinction
  # portée par un "/" NU collé devant CE marqueur précis, jamais par un accord nommé
  # (le "/F://C:" ci-dessus garde tel quel son sens de fusion, inchangé).
  describe "\"//[B]:\" vs \"/[B]:\" : note aiguë ou VRAIE basse (issue Carnet-1)" do
    it "\"/[B]:\" (un seul \"/\") : NOTE AIGUË — chord = \"[B]\", SANS préfixe" do
      segments = DSLParser.parse_line("/[B]:si")
      expect(segments.first.chord).to eq("[B]")
    end

    it "\"//[B]:\" (\"/\" NU + marqueur) : VRAIE basse — chord = \"/[B]\", le \"/\" nu devient un préfixe SUR le champ chord" do
      segments = DSLParser.parse_line("//[B]:si")
      expect(segments.first.chord).to eq("/[B]")
      expect(segments.first.text).to eq("si")
    end

    it "en tout début de ligne (aucun caractère avant) : même distinction, pas d'erreur d'index" do
      expect(DSLParser.parse_line("/[B]:x").first.chord).to eq("[B]")
      expect(DSLParser.parse_line("//[B]:x").first.chord).to eq("/[B]")
    end

    it "un \"/\" nu devant un accord NOMMÉ (pas un bracket) garde son sens D'ORIGINE : texte ignoré, jamais un préfixe" do
      segments = DSLParser.parse_line("mot //Bm:reste")
      expect(segments.map(&:chord).compact).to eq(["Bm"])
      expect(segments.map(&:text).join).not_to include("/")
    end
  end

  describe "découper le fichier en morceaux" do
    it "Séparer les informations du début (frontmatter) du reste des paroles" do
      song = DSLParser.parse("---\ntitle: Test\n---\nBonjour\n")
      expect(song.meta["title"]).to eq("Test")
      expect(song.blocks.first.lines.first.segments.first.text).to eq("Bonjour")
    end

    it "Lire les indications entre accolades au début d'un morceau" do
      song = DSLParser.parse("{tabs: intro.tab; shrink: true;}\nParoles\n")
      expect(song.blocks.first.directives).to eq({ tabs: "intro.tab", shrink: "true" })
    end

    it "Savoir que deux morceaux vont côte à côte (//)" do
      song = DSLParser.parse("Premier\n\n//\n\nDeuxième\n")
      expect(song.blocks[1].paired_with_previous).to be true
    end
  end
end
