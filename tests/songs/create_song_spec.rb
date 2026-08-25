# frozen_string_literal: true

require_relative "../spec_helper"
require "song_creator"
require "fileutils"

# Tests des assistants
RSpec.describe "assistant de création de chanson" do
  let(:prompt) { instance_double(TTY::Prompt) }
  let(:created_folder) { File.join(FIXTURE_SONGS_DIR, "Chanson De Test") }

  before do
    allow(TTY::Prompt).to receive(:new).and_return(prompt)
    allow(SongCreator).to receive(:system).and_return(true)
  end

  after { FileUtils.rm_rf(created_folder) }

  it "Créer une chanson avec les bonnes données" do
    allow(SongCreator).to receive(:find_year_candidates).and_return([])
    allow(SongCreator).to receive(:find_composer_lyricist).and_return({ composer: nil, lyricist: nil, wikipedia_pageid: nil })
    allow(SongCreator).to receive(:fetch_lyrics).and_return(nil)
    allow(prompt).to receive(:ask).with("Année :").and_return("2020")
    allow(prompt).to receive(:ask).with("Compositeur :", default: nil).and_return("Compositeur Test")
    allow(prompt).to receive(:ask).with("Parolier :", default: nil).and_return("Parolier Test")
    allow(prompt).to receive(:yes?).and_return(false)

    folder = SongCreator.run("Chanson De Test", "Artiste Test")

    expect(folder).to eq(created_folder)
    expect(File.exist?(File.join(created_folder, "c.infos"))).to be true
    infos = File.read(File.join(created_folder, "c.infos"))
    expect(infos).to include("title: Chanson De Test")
    expect(infos).to include("performer: Artiste Test")
    expect(infos).to include("composer: Compositeur Test")
    expect(infos).to include("year: 2020")
  end

  it "Retrouver une chanson déjà créée au lieu d'en refaire une" do
    allow(prompt).to receive(:select).and_return(:open)
    allow(prompt).to receive(:yes?).and_return(false)

    result = SongCreator.run("Angie", "Rolling Stones")

    expect(result).to be_nil # branche "open", ne crée rien de nouveau
    expect(Dir.exist?(File.join(FIXTURE_SONGS_DIR, "Chanson De Test"))).to be false
  end

  it "Ne pas planter si la recherche sur internet échoue" do
    allow(Net::HTTP).to receive(:start).and_raise(SocketError, "panne réseau simulée")

    expect(SongCreator.discogs_year("Angie", "Rolling Stones")).to be_nil
    expect(SongCreator.fetch_lyrics("Angie", "Rolling Stones")).to be_nil
  end
end
