# frozen_string_literal: true

require_relative "../spec_helper"
require "cli"
require "session"
require "fileutils"

# Tests du mode interactif — `create song`/`create songbook` doivent devenir le
# contexte courant (bug 2026-08-26 : l'ancien `use song`/`use songbook` restait en
# place après une création).
RSpec.describe "create song/songbook devient le contexte courant" do
  let(:prompt) { instance_double(TTY::Prompt) }

  before { allow(TTY::Prompt).to receive(:new).and_return(prompt) }

  describe "create song" do
    let(:created_folder) { File.join(FIXTURE_SONGS_DIR, "Chanson De Test") }

    before { allow(SongCreator).to receive(:system).and_return(true) }
    after { FileUtils.rm_rf(created_folder) }

    it "remplace une chanson déjà en contexte (use song) par la chanson nouvellement créée" do
      CLI.run(%w[use song Angie], interactive: true)
      expect(Session.song).to eq(File.join(FIXTURE_SONGS_DIR, "Angie"))

      allow(SongCreator).to receive(:find_year_candidates).and_return([])
      allow(SongCreator).to receive(:find_composer_lyricist).and_return({ composer: nil, lyricist: nil, wikipedia_pageid: nil })
      allow(SongCreator).to receive(:fetch_lyrics).and_return(nil)
      allow(prompt).to receive(:ask).with(SongCreator.blue("Année :")).and_return("2020")
      allow(prompt).to receive(:ask).with(SongCreator.blue("Compositeur :"), default: nil).and_return("Compositeur Test")
      allow(prompt).to receive(:ask).with(SongCreator.blue("Parolier :"), default: nil).and_return("Parolier Test")
      allow(prompt).to receive(:yes?).and_return(false)

      CLI.run(["create", "song", "Chanson De Test", "Artiste Test"], interactive: true)

      expect(Session.song).to eq(created_folder)
    end
  end

  describe "create songbook" do
    let(:created_folder) { File.join(FIXTURE_SONGBOOKS_DIR, "Carnet-De-Test-Assistant") }

    before { allow(SongbookCreator).to receive(:system).and_return(true) }
    after { FileUtils.rm_rf(created_folder) }

    it "remplace un carnet déjà en contexte (use songbook) par le carnet nouvellement créé" do
      CLI.run(%w[use songbook Carnet-Test], interactive: true)
      expect(Session.carnet).to eq(File.join(FIXTURE_SONGBOOKS_DIR, "Carnet-Test"))

      allow(prompt).to receive(:ask).with(SongbookCreator.blue("Titre du carnet :")).and_return("Mon Carnet Test")
      allow(prompt).to receive(:ask).with(SongbookCreator.blue("Nom du dossier :"), default: "Carnet-mon-carnet-test").and_return("Carnet-De-Test-Assistant")
      allow(prompt).to receive(:ask).with(SongbookCreator.blue("Sous-titre (rien si aucun) :")).and_return("")
      allow(prompt).to receive(:ask).with(SongbookCreator.blue("Prix (ex. 9,90 € — rien si inconnu) :")).and_return("")
      allow(prompt).to receive(:ask).with(SongbookCreator.blue("Nom de l'éditeur (rien si aucun) :")).and_return("")
      allow(prompt).to receive(:ask).with(SongbookCreator.blue("Conception du carnet (rien si inconnu) :")).and_return("")
      allow(prompt).to receive(:yes?).and_return(false)

      CLI.run(%w[create songbook], interactive: true)

      expect(Session.carnet).to eq(created_folder)
    end
  end
end
