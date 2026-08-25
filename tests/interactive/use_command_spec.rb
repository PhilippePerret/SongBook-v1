# frozen_string_literal: true

require_relative "../spec_helper"
require "cli"
require "session"
require "fileutils"

# Tests du mode interactif
RSpec.describe "mode interactif : chanson/carnet courant (use)" do
  let(:carnet_export) { File.join(FIXTURE_SONGBOOKS_DIR, "Carnet-Test", "export") }

  after { FileUtils.rm_rf(carnet_export) }

  it "Se souvenir de la chanson choisie avec use" do
    CLI.run(%w[use song Angie], interactive: true)
    expect(Session.song).to eq(File.join(FIXTURE_SONGS_DIR, "Angie"))
  end

  it "Se souvenir du carnet choisi avec use" do
    CLI.run(["use", "songbook", "Carnet-Test"], interactive: true)
    expect(Session.carnet).to eq(File.join(FIXTURE_SONGBOOKS_DIR, "Carnet-Test"))
  end

  # Bug constaté 2026-08-25 : `build` sans argument ignorait le carnet choisi avec
  # `use` et construisait le dossier courant à la place.
  it "Construire le bon carnet même sans rien taper après use" do
    CLI.run(["use", "songbook", "Carnet-Test"], interactive: true)
    expect(Session.carnet).not_to be_nil

    expect { CLI.run(["build"], interactive: true) }.not_to raise_error
    expect(Dir.exist?(carnet_export)).to be true
  end

  it "Utiliser une chanson une seule fois avec --song" do
    CLI.run(%w[song id --song Angie], interactive: true)
    expect(Session.song).to be_nil
  end
end
