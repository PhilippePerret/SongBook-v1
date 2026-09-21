# frozen_string_literal: true

require_relative "../spec_helper"
require "layout"
require "transpose"
require "dsl_parser"

# Rendu ("gravure") des accords : la fondamentale garde les lettres A-G (`convert_note_symbol`),
# mais la basse entre crochets (`A[c]m7`, `[fd]` seule) suit une règle DIFFÉRENTE (Phil,
# 2026-08-28) : toujours en solfège ITALIEN (do/ré/mi/fa/sol/la/si), toujours en minuscule.
RSpec.describe "Layout : affichage des accords (basse en solfège italien)" do
  describe "Transpose.italian_bass_symbol" do
    it "convertit chaque lettre en syllabe italienne" do
      expect(Transpose.italian_bass_symbol("a")).to eq("la")
      expect(Transpose.italian_bass_symbol("b")).to eq("si")
      expect(Transpose.italian_bass_symbol("c")).to eq("do")
      expect(Transpose.italian_bass_symbol("d")).to eq("ré")
      expect(Transpose.italian_bass_symbol("e")).to eq("mi")
      expect(Transpose.italian_bass_symbol("f")).to eq("fa")
      expect(Transpose.italian_bass_symbol("g")).to eq("sol")
    end

    it "dièse (\"d\" en 2e position) -> ♯ APRÈS la syllabe" do
      expect(Transpose.italian_bass_symbol("fd")).to eq("fa♯")
    end

    it "bémol (\"b\" en 2e position) -> ♭ après la syllabe" do
      expect(Transpose.italian_bass_symbol("bb")).to eq("si♭") # "bb" = si BÉMOL
    end

    it "toujours en minuscule, même si la fondamentale de la basse est en majuscule" do
      # Le stockage (`DSLParser.normalize_chord`) garantit déjà l'alteration ("d"/"b")
      # en minuscule — seule la lettre racine (1re position) est testée ici en majuscule.
      expect(Transpose.italian_bass_symbol("F")).to eq("fa")
      expect(Transpose.italian_bass_symbol("Fd")).to eq("fa♯")
    end
  end

  describe ".display_chord (basse embarquée ou seule)" do
    # 2026-09-07 (Phil : "[B] n'est pas obligatoirement une basse, ça évolue") : un
    # bracket SEUL n'est PLUS automatiquement une basse — "[fd]:" seul (sans "/" NU
    # devant, voir `DSLParser::BARE_BASS_RE`) est désormais une NOTE AIGUË à jouer,
    # affichée SANS "/". Seul "//[fd]:" (le "/" posé par `DSLParser.parse_line`,
    # préfixe interne "/[fd]") reste une VRAIE basse, affichée "/<syllabe>" comme avant.
    it "bracket seul, SANS \"/\" devant (\"[fd]:\") : NOTE AIGUË -> syllabe italienne SANS \"/\"" do
      expect(Layout.display_chord("[fd]")).to eq("fa♯")
    end

    it "bracket préfixé d'un \"/\" (\"//[fd]:\", stocké \"/[fd]\") : VRAIE basse -> \"/<syllabe italienne>\"" do
      expect(Layout.display_chord("/[fd]")).to eq("/fa♯")
    end

    it "basse embarquée dans un accord : fondamentale en lettre, basse en italien (inchangé, jamais ambigu)" do
      expect(Layout.display_chord("Am7[c]")).to eq("Am7/do")
    end

    it "fondamentale seule (sans basse) : comportement inchangé (lettres A-G)" do
      expect(Layout.display_chord("Am7")).to eq("Am7")
      expect(Layout.display_chord("Fd")).to eq("F♯")
    end
  end

  # Issue #106 ("Jamais Partir") : la basse embarquée doit se rapprocher de SON "/",
  # jamais de l'accord suivant — mais un accord COMPOSÉ ("Bb6/C", 2 accords distincts
  # collés, `ChordDiagrams.split_chord`) garde un écart NORMAL des deux côtés de son "/".
  describe ".slash_bass_flags" do
    it "basse embarquée (\"G6[B]\") : le \"/\" affiché est une basse" do
      expect(Layout.slash_bass_flags("G6[B]")).to eq([true])
    end

    it "accord composé (\"Bb6/C\") : le \"/\" affiché N'est PAS une basse" do
      expect(Layout.slash_bass_flags("Bb6/C")).to eq([false])
    end

    it "basse seule (\"/[fd]\") : nil, repli sur l'ancien critère (déjà resserré)" do
      expect(Layout.slash_bass_flags("/[fd]")).to be_nil
    end
  end

  describe ".slash_label_width (écart resserré après le \"/\" d'une basse embarquée)" do
    it "une basse embarquée mesure moins large qu'un accord composé à noms égaux" do
      pdf = Prawn::Document.new
      Layout.register_fonts(pdf)
      bass_w = Layout.slash_label_width(pdf, "G6/si", Layout::CHORD_SIZE, bass_flags: Layout.slash_bass_flags("G6[B]"))
      composite_w = Layout.slash_label_width(pdf, "G6/si", Layout::CHORD_SIZE, bass_flags: Layout.slash_bass_flags("G6/si"))
      expect(bass_w).to be < composite_w
    end

    it "1pt de moins UNIQUEMENT avant le \"/\" (entre l'accord et le \"/\"), après inchangé" do
      expect(Layout::CHORD_SLASH_GAP_BASS_LEAD).to eq(Layout::CHORD_SLASH_GAP - 1.0)
      expect(Layout::CHORD_SLASH_GAP_BASS_TRAIL).to eq(Layout::CHORD_SLASH_GAP_BASS_ONLY)
    end

    it "séparateur ACCORD COMPOSÉ (2 accords collés, ex. fusion \"G6[B]\"+\"Gm6[Bb]\") : 2pt de plus des 2 côtés" do
      expect(Layout::CHORD_SLASH_GAP_COMPOSITE_LEAD).to eq(Layout::CHORD_SLASH_GAP + 2.0)
      expect(Layout::CHORD_SLASH_GAP_COMPOSITE_TRAIL).to eq(Layout::CHORD_SLASH_GAP + 2.0)
      expect(Layout.slash_gaps(Layout.slash_bass_flags("Bb6/C"), 0, "Bb6")).to eq([Layout::CHORD_SLASH_GAP_COMPOSITE_LEAD, Layout::CHORD_SLASH_GAP_COMPOSITE_TRAIL])
    end
  end

  # Issue #106 (suite) : 2 accords qui se suivent SANS retomber sur des paroles ("Jamais
  # Partir", fin du 1er vers du refrain et 2e "Jamais partir") -> `CHORD_VOID_GAP` en plus.
  describe ".text_line_steps (écart accord/accord \"dans le vide\")" do
    it "ajoute CHORD_VOID_GAP quand rien ne tombe entre 2 accords consécutifs" do
      pdf = Prawn::Document.new
      Layout.register_fonts(pdf)
      void_segments = [
        Segment.new(chord: "G6[B]", fret: "0", text: ""),
        Segment.new(chord: "Gm6[Bb]", fret: "0", text: "")
      ]
      no_void_segments = [
        Segment.new(chord: "G6[B]", fret: "0", text: ""),
        Segment.new(chord: nil, fret: nil, text: "x")
      ]
      void_steps, = Layout.text_line_steps(pdf, void_segments, Layout::CHORD_SIZE, Layout::TEXT_SIZE)
      no_void_steps, = Layout.text_line_steps(pdf, no_void_segments, Layout::CHORD_SIZE, Layout::TEXT_SIZE)
      expect(void_steps[1][:x] - no_void_steps[1][:x]).to eq(Layout::CHORD_VOID_GAP)
    end

    it "un espace SEUL entre 2 accords compte AUSSI comme \"dans le vide\"" do
      pdf = Prawn::Document.new
      Layout.register_fonts(pdf)
      space_segments = [
        Segment.new(chord: "G6[B]", fret: "0", text: " "),
        Segment.new(chord: "Gm6[Bb]", fret: "0", text: "")
      ]
      no_void_segments = [
        Segment.new(chord: "G6[B]", fret: "0", text: " "),
        Segment.new(chord: nil, fret: nil, text: "x")
      ]
      space_steps, = Layout.text_line_steps(pdf, space_segments, Layout::CHORD_SIZE, Layout::TEXT_SIZE)
      no_void_steps, = Layout.text_line_steps(pdf, no_void_segments, Layout::CHORD_SIZE, Layout::TEXT_SIZE)
      expect(space_steps[1][:x] - no_void_steps[1][:x]).to eq(Layout::CHORD_VOID_GAP)
    end

    it "de vraies paroles entre 2 accords : pas de supplément" do
      pdf = Prawn::Document.new
      Layout.register_fonts(pdf)
      segments = [
        Segment.new(chord: "G6[B]", fret: "0", text: "x"),
        Segment.new(chord: "Gm6[Bb]", fret: "0", text: "")
      ]
      steps, = Layout.text_line_steps(pdf, segments, Layout::CHORD_SIZE, Layout::TEXT_SIZE)
      chord_w = Layout.chord_label_width(pdf, "G6[B]", Layout::CHORD_SIZE)
      expect(steps[1][:x]).to eq(chord_w + Layout::CHORD_GAP)
    end
  end
end
