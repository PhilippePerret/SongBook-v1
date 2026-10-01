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
    allow(SongCreator).to receive(:colored_prompt).and_return(prompt)
    allow(SongCreator).to receive(:system).and_return(true)
  end

  after { FileUtils.rm_rf(created_folder) }

  it "Créer une chanson avec les bonnes données" do
    allow(SongCreator).to receive(:find_year_candidates).and_return([])
    allow(SongCreator).to receive(:find_composer_lyricist).and_return({ composer: nil, lyricist: nil, wikipedia_pageid: nil })
    allow(SongCreator).to receive(:fetch_lyrics).and_return(nil)
    allow(prompt).to receive(:ask).with(SongCreator.yellow("Année :")).and_return("2020")
    allow(prompt).to receive(:ask).with(SongCreator.yellow("Compositeur :"), default: nil).and_return("Compositeur Test")
    allow(prompt).to receive(:ask).with(SongCreator.yellow("Parolier :"), default: nil).and_return("Parolier Test")
    allow(prompt).to receive(:ask).with(SongCreator.yellow("Identifiant :"), default: anything) { |_, opts| opts[:default] }
    allow(prompt).to receive(:yes?).and_return(false)

    folder = SongCreator.run("Chanson De Test", "Artiste Test")

    expect(folder).to eq(created_folder)
    expect(File.exist?(File.join(created_folder, "c.infos"))).to be true
    infos = File.read(File.join(created_folder, "c.infos"))
    expect(infos).to include("title: Chanson De Test")
    expect(infos).to include("performer: Artiste Test")
    expect(infos).to include("composer: Compositeur Test")
    expect(infos).to include("year: 2020")
    expect(Dir.exist?(File.join(created_folder, "images"))).to be true
    expect(Dir.exist?(File.join(created_folder, "scores"))).to be true
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

  describe "identifiant de la chanson" do
    it "retire l'article de tête du titre (français et anglais)" do
      expect(CarnetBuilder.song_id("Le Pénitencier", "Johnny Hallyday", "1964")).to eq("penitencier-johnny-hallyday-1964")
      expect(CarnetBuilder.song_id("L'Aigle noir", "Barbara", "1970")).to eq("aigle-noir-barbara-1970")
      expect(CarnetBuilder.song_id("The Wall", "Pink Floyd", "1979")).to eq("wall-pink-floyd-1979")
      expect(CarnetBuilder.song_id("A Bicyclette", "Yves Montand", "1968")).to eq("bicyclette-yves-montand-1968")
      expect(CarnetBuilder.song_id("Une belle histoire", "Michel Fugain", "1972")).to eq("belle-histoire-michel-fugain-1972")
    end

    it "ne retire pas un mot qui commence seulement comme un article" do
      expect(CarnetBuilder.song_id("Angie", "Rolling Stones", "1973")).to eq("angie-rolling-stones-1973")
      expect(CarnetBuilder.song_id("Lettre à France", "Michel Polnareff", "1977")).to eq("lettre-a-france-michel-polnareff-1977")
    end

    it "retire « et »/« and » du performer" do
      expect(CarnetBuilder.song_id("Le Lac", "Michel et Jonaz", "1980")).to eq("lac-michel-jonaz-1980")
      expect(CarnetBuilder.song_id("Cecilia", "Simon and Garfunkel", "1970")).to eq("cecilia-simon-garfunkel-1970")
    end

    it "supprime les apostrophes sans les remplacer par un tiret" do
      expect(CarnetBuilder.song_id("Comme d'habitude", "Claude François", "1967")).to eq("comme-dhabitude-claude-francois-1967")
      expect(CarnetBuilder.song_id("Comme d’habitude", "Claude François", "1967")).to eq("comme-dhabitude-claude-francois-1967")
    end

    it "laisse l'user confirmer ou changer l'identifiant avant création" do
      allow(SongCreator).to receive(:find_year_candidates).and_return([])
      allow(SongCreator).to receive(:find_composer_lyricist).and_return({ composer: nil, lyricist: nil, wikipedia_pageid: nil })
      allow(SongCreator).to receive(:fetch_lyrics).and_return(nil)
      allow(prompt).to receive(:ask).with(SongCreator.yellow("Année :")).and_return("2020")
      allow(prompt).to receive(:ask).with(SongCreator.yellow("Compositeur :"), default: nil).and_return("C")
      allow(prompt).to receive(:ask).with(SongCreator.yellow("Parolier :"), default: nil).and_return("P")
      expect(prompt).to receive(:ask).with(SongCreator.yellow("Identifiant :"), default: "chanson-de-test-artiste-test-2020").and_return("mon-id-perso")
      allow(prompt).to receive(:yes?).and_return(false)

      SongCreator.run("Chanson De Test", "Artiste Test")

      expect(File.read(File.join(created_folder, "c.infos"))).to include("id: mon-id-perso")
    end
  end
end
