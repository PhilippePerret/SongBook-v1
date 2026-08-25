# frozen_string_literal: true

require_relative "../spec_helper"
require "chord_diagrams"
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

  it "Ne pas planter quand aucun diagramme n'est trouvé nulle part" do
    Dir.mktmpdir do |dir|
      expect(ChordDiagrams.diag_path("Zzz9", carnet_dir: dir)).to be_nil
    end
  end
end
