# frozen_string_literal: true

require_relative "../spec_helper"
require "chord_diagrams"
require "dsl_parser"
require "fileutils"
require "tmpdir"

# Tests des outils
RSpec.describe "recherche des diagrammes d'accords" do
  around do |example|
    Dir.mktmpdir do |dir|
      Layout.conflict_log_path = File.join(dir, "conflicts.log")
      File.write(Layout.conflict_log_path, "")
      example.run
    end
  end

  it "Reconnaître un accord transposé (dièse/bémol) écrit avec le vrai symbole musical" do
    expect(ChordDiagrams.file_chord("B♭7M")).to eq("Bb7M")
    expect(ChordDiagrams.file_chord("F♯m")).to eq("F#m")
  end

  it "Préférer le diagramme du carnet à celui de la chanson" do
    Dir.mktmpdir do |carnet_dir|
      Dir.mktmpdir do |song_dir|
        File.write(File.join(carnet_dir, "A-0.svg"), "<svg carnet/>")
        File.write(File.join(song_dir, "A-0.svg"), "<svg chanson/>")

        found = ChordDiagrams.diag_path("A", carnet_dir: carnet_dir, song_dir: song_dir)
        expect(found).to eq(File.join(carnet_dir, "A-0.svg"))
      end
    end
  end

  it "Choisir la case la plus basse quand aucune case n'est précisée" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "A-5.svg"), "")
      File.write(File.join(dir, "A-0.svg"), "")
      found = ChordDiagrams.diag_path("A", carnet_dir: dir)
      expect(found).to eq(File.join(dir, "A-0.svg"))
    end
  end

  it "Choisir exactement la case demandée si elle est précisée" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "A-5.svg"), "")
      File.write(File.join(dir, "A-0.svg"), "")
      found = ChordDiagrams.diag_path("A", fret: "5", carnet_dir: dir)
      expect(found).to eq(File.join(dir, "A-5.svg"))
    end
  end

  it "trouve un fichier enregistré dans une AUTRE casse (bug constaté : \"c[e]-0B.svg\" introuvable via le nom canonique \"C[E]\")" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "c[e]-0B.svg"), "")
      found = ChordDiagrams.diag_path("C[E]", fret: "0B", carnet_dir: dir)
      expect(found).to eq(File.join(dir, "c[e]-0B.svg"))
    end
  end

  it "la qualité/altération GARDE sa casse exacte (\"Zm\"/\"ZM\" 2 accords différents, jamais confondus)" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "ZM-0.svg"), "")
      expect(ChordDiagrams.diag_path("Zm", carnet_dir: dir)).to be_nil
    end
  end

  it "Ne pas planter quand aucun diagramme n'est trouvé nulle part" do
    Dir.mktmpdir do |dir|
      expect(ChordDiagrams.diag_path("Zzz9", carnet_dir: dir)).to be_nil
    end
  end

  # Générique (sans "-case") vs précis (avec) : un générique rencontré APRÈS un précis
  # du même nom hérite de SA case, plutôt que de chercher la case la plus basse (Phil,
  # 2026-08-28).
  describe ".collect_chord_frets (générique hérite du précis rencontré avant lui)" do
    def blocks_from(pairs)
      segments = pairs.map { |chord, fret| Segment.new(chord: chord, fret: fret, text: "x") }
      line = Line.new(segments: segments, label: nil, align: nil)
      [Block.new(lines: [line], directives: {}, paired_with_previous: false)]
    end

    it "générique AVANT tout précis : reste générique (case la plus basse cherchée normalement)" do
      blocks = blocks_from([["D6", nil]])
      expect(ChordDiagrams.collect_chord_frets(blocks)).to eq([["D6", nil]])
    end

    it "générique APRÈS un précis du même nom : traité comme CE précis (exemple de l'énoncé)" do
      # "D6" (générique) puis "D6-10R" (précis) puis de nouveau "D6" (générique,
      # désormais résolu comme "D6-10R" — pas une 3e entrée séparée).
      blocks = blocks_from([["D6", nil], ["D6", "10R"], ["D6", nil]])
      expect(ChordDiagrams.collect_chord_frets(blocks)).to eq([["D6", nil], ["D6", "10R"]])
    end

    it "plusieurs précis successifs du même nom : chaque générique hérite du DERNIER précis rencontré" do
      blocks = blocks_from([["D6", "3"], ["D6", nil], ["D6", "10R"], ["D6", nil]])
      expect(ChordDiagrams.collect_chord_frets(blocks)).to eq([["D6", "3"], ["D6", "10R"]])
    end

    it "des accords différents ne s'influencent pas entre eux" do
      blocks = blocks_from([["D6", "10R"], ["Am", nil]])
      expect(ChordDiagrams.collect_chord_frets(blocks)).to eq([["D6", "10R"], ["Am", nil]])
    end

    it "un accord \"/\"-composé (\"Bb6/C\") est scindé en 2 accords distincts, pas un manquant" do
      blocks = blocks_from([["Bb6/C", nil], ["Bb6/A7", nil], ["Am7/G", nil]])
      expect(ChordDiagrams.collect_chord_frets(blocks)).to eq(
        [["Bb6", nil], ["C", nil], ["Bb6", nil], ["A7", nil], ["Am7", nil], ["G", nil]].uniq
      )
    end
  end

  describe ".split_chord" do
    it "scinde sur \"/\" (jamais un accord+basse, ça c'est les crochets — Manuel/song/chords.adoc)" do
      expect(ChordDiagrams.split_chord("Bb6/C")).to eq(%w[Bb6 C])
    end

    it "laisse intact un accord sans \"/\"" do
      expect(ChordDiagrams.split_chord("Am7")).to eq(["Am7"])
    end
  end
end
