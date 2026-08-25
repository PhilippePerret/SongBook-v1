# frozen_string_literal: true

require_relative "../spec_helper"
require "carnet_builder"
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
end
