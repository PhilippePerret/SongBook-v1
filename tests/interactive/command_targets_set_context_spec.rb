# frozen_string_literal: true

require_relative "../spec_helper"
require "cli"
require "session"
require "file_finder"
require "fileutils"

# Issue #59 : jusqu'ici SEULES `use`/`create` faisaient de leur cible le contexte
# courant. Toute commande qui cible une chanson/un carnet par son nom doit faire
# de même (sans passer par `use` d'abord).
RSpec.describe "toute commande ciblant une chanson/un carnet devient le contexte courant" do
  let(:angie) { File.join(FIXTURE_SONGS_DIR, "Angie") }
  let(:carnet_test) { File.join(FIXTURE_SONGBOOKS_DIR, "Carnet-Test") }

  before { Session.song = nil; Session.carnet = nil }

  it "'edit chords <chanson>' fixe le contexte, sans 'use' préalable" do
    allow(ChordPlacer).to receive(:run)
    CLI.run(%w[edit chords Angie], interactive: true)
    expect(Session.song).to eq(angie)
  end

  it "'song id <chanson>' fixe le contexte" do
    allow(IO).to receive(:popen)
    CLI.run(%w[song id Angie], interactive: true)
    expect(Session.song).to eq(angie)
  end

  it "'open song <chanson>' fixe le contexte" do
    allow_any_instance_of(TTY::Prompt).to receive(:multi_select).and_return([])
    CLI.run(%w[open song Angie], interactive: true)
    expect(Session.song).to eq(angie)
  end

  it "'build <chanson>' fixe le contexte" do
    export_dir = File.join(angie, "export")
    allow_any_instance_of(TTY::Prompt).to receive(:yes?).and_return(false)

    CLI.run(%w[build Angie], interactive: true)
    expect(Session.song).to eq(angie)
  ensure
    FileUtils.rm_rf(export_dir)
  end

  it "'open tdm <carnet>' fixe le contexte" do
    allow(CLI).to receive(:system)
    CLI.run(%w[open tdm Carnet-Test], interactive: true)
    expect(Session.carnet).to eq(carnet_test)
  end

  it "'cover dims <carnet>' fixe le contexte" do
    CLI.run(%w[cover dims Carnet-Test], interactive: true)
    expect(Session.carnet).to eq(carnet_test)
  end
end
