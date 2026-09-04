# frozen_string_literal: true

require_relative "../spec_helper"
require "carnet_builder"
require "page_builder"
require "fileutils"
require "tmpdir"

# Tests des chansons
RSpec.describe "construction d'une chanson seule" do
  let(:song_folder) { File.join(FIXTURE_SONGS_DIR, "Angie") }
  let(:export_dir) { File.join(song_folder, "export") }

  after { FileUtils.rm_rf(export_dir) }

  it "Construire une chanson toute seule" do
    out_path = CarnetBuilder.build_song(song_folder)

    expect(File.exist?(out_path)).to be true
    expect(File.size(out_path)).to be > 0
  end

  it "Refuser un dossier qui n'a pas de paroles" do
    Dir.mktmpdir do |dir|
      expect(CarnetBuilder.song_folder?(dir)).to be false
    end
  end

  it "reconnaît un dossier de chanson valide" do
    expect(CarnetBuilder.song_folder?(song_folder)).to be true
  end

  it "log de conflits : liste des accords manquants sur la DERNIÈRE ligne, avec leur nom exact" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "c.lyr"), "{couplet-1}\n/Zzz9:Un accord qui n'existe pas\n")
      File.write(File.join(dir, "c.infos"), "title: Test Log\n")

      CarnetBuilder.build_song(dir)

      conflict_log = Dir.glob(File.join(dir, "export", "*-conflicts.log")).first
      lines = File.readlines(conflict_log).map(&:chomp).reject(&:empty?)
      # Chanson SEULE : PAS de titre entre parenthèses  — toujours
      # celui de cette même chanson ici, purement redondant (contrairement à un carnet,
      # où plusieurs chansons peuvent partager le même accord manquant).
      expect(lines.last).to eq("ACCORDS MANQUANTS : Zzz9")
    end
  end

  describe "en-tête de bloc .lyr avec directives inline (issue #68, \"{intro; label: INTRO;}\")" do
    def blocks_for(lyr_body)
      Dir.mktmpdir do |dir|
        path = File.join(dir, "c.lyr")
        File.write(path, lyr_body)
        return PageBuilder.parse_lyr(path)
      end
    end

    it "reconnu comme en-tête (jamais écrit en toutes lettres dans les paroles), avec \";\" final" do
      blocks, = blocks_for("{intro; label: REFRAIN;}\n/G:bonjour\n")
      texts = blocks["intro"].lines.map { |l| l.segments.map(&:text).join }
      expect(texts).not_to include(a_string_including("label"))
      expect(texts).not_to include(a_string_including(";"))
    end

    it "dernière propriété SANS \";\" final : reconnu quand même" do
      blocks, = blocks_for("{intro; label: \"INTRO\"}\n/G:bonjour\n")
      texts = blocks["intro"].lines.map { |l| l.segments.map(&:text).join }
      expect(texts).not_to include(a_string_including("label"))
    end

    it "\"label:\" (issue #63) : gardé comme directive du bloc, jamais ajouté comme ligne du corps — dessiné à part, en regard de la 1re ligne (Layout.draw_block)" do
      blocks, = blocks_for("{intro; label: \"INTRO\"}\n/G:bonjour\n")
      block = blocks["intro"]
      expect(block.directives[:label]).to eq("INTRO")
      expect(block.lines.map { |l| l.segments.map(&:text).join }).to eq(["bonjour"])
    end
  end
end
