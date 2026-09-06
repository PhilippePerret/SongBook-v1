# frozen_string_literal: true

require_relative "../spec_helper"
require "page_builder"
require "carnet_builder"
require "tmpdir"

# `diags_shrink`/`tabs_shrink`/`scores_shrink` (`.infos` chanson prioritaire sur le
# carnet) — voir `Options`.
RSpec.describe "options diags_shrink/tabs_shrink/scores_shrink" do
  around do |example|
    Dir.mktmpdir do |dir|
      @carnet_folder = File.join(dir, "carnet")
      @song_folder = File.join(dir, "song")
      FileUtils.mkdir_p(@carnet_folder)
      FileUtils.mkdir_p(@song_folder)
      example.run
    end
  end

  def write_carnet_infos(content)
    File.write(File.join(@carnet_folder, "c.infos"), content)
  end

  def resolve(key, song_infos: "title: Chanson\n")
    File.write(File.join(@song_folder, "c.infos"), song_infos)
    Options.load!(meta: {}, infos_path: File.join(@song_folder, "c.infos"), carnet_folder: @carnet_folder)
    Options.get(key)
  end

  it "true par défaut, absente de la chanson et du carnet" do
    write_carnet_infos("title: Carnet\n")
    expect(resolve(:diags_shrink)).to eq(true)
  end

  it "true par défaut, sans carnet du tout (chanson seule)" do
    File.write(File.join(@song_folder, "c.infos"), "title: Chanson\n")
    Options.load!(meta: {}, infos_path: File.join(@song_folder, "c.infos"), carnet_folder: nil)
    expect(Options.get(:diags_shrink)).to eq(true)
  end

  it "valeur du carnet reprise si absente de la chanson" do
    write_carnet_infos("title: Carnet\ndiags_shrink: false\n")
    expect(resolve(:diags_shrink)).to eq(false)
  end

  it "la chanson est prioritaire sur le carnet" do
    write_carnet_infos("title: Carnet\ndiags_shrink: false\n")
    expect(resolve(:diags_shrink, song_infos: "title: Chanson\ndiags_shrink: true\n")).to eq(true)
  end

  it "la chanson peut aussi désactiver malgré un carnet à true" do
    write_carnet_infos("title: Carnet\ndiags_shrink: true\n")
    expect(resolve(:diags_shrink, song_infos: "title: Chanson\ndiags_shrink: false\n")).to eq(false)
  end

  it "chaque propriété (diags_shrink/tabs_shrink/scores_shrink) se résout indépendamment" do
    write_carnet_infos("title: Carnet\ntabs_shrink: false\n")
    song_infos = "title: Chanson\nscores_shrink: false\n"
    expect(resolve(:diags_shrink, song_infos: song_infos)).to eq(true)
    expect(resolve(:tabs_shrink, song_infos: song_infos)).to eq(false)
    expect(resolve(:scores_shrink, song_infos: song_infos)).to eq(false)
  end

  describe "shrink_text (défaut FALSE, inverse des autres)" do
    it "false par défaut, absent de la chanson et du carnet" do
      write_carnet_infos("title: Carnet\n")
      expect(resolve(:shrink_text)).to eq(false)
    end

    it "le carnet peut l'activer explicitement" do
      write_carnet_infos("title: Carnet\nshrink_text: true\n")
      expect(resolve(:shrink_text)).to eq(true)
    end

    it "la chanson reste prioritaire sur le carnet, comme les autres" do
      write_carnet_infos("title: Carnet\nshrink_text: true\n")
      expect(resolve(:shrink_text, song_infos: "title: Chanson\nshrink_text: false\n")).to eq(false)
    end
  end
end
