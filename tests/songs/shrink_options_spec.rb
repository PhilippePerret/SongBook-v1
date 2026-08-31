# frozen_string_literal: true

require_relative "../spec_helper"
require "page_builder"
require "tmpdir"

# `shrink_diags`/`shrink_tabla`/`shrink_score` (`.infos` chanson prioritaire sur le
# carnet) — voir `PageBuilder.resolve_shrink_option`.
RSpec.describe "options shrink_diags/shrink_tabla/shrink_score" do
  around do |example|
    Dir.mktmpdir do |dir|
      @carnet_folder = File.join(dir, "carnet")
      FileUtils.mkdir_p(@carnet_folder)
      example.run
    end
  end

  def write_carnet_infos(content)
    File.write(File.join(@carnet_folder, "c.infos"), content)
  end

  it "true par défaut, absente de la chanson et du carnet" do
    write_carnet_infos("title: Carnet\n")
    expect(PageBuilder.resolve_shrink_option({}, @carnet_folder, "shrink_diags")).to eq(true)
  end

  it "true par défaut, sans carnet du tout (chanson seule)" do
    expect(PageBuilder.resolve_shrink_option({}, nil, "shrink_diags")).to eq(true)
  end

  it "valeur du carnet reprise si absente de la chanson" do
    write_carnet_infos("title: Carnet\nshrink_diags: false\n")
    expect(PageBuilder.resolve_shrink_option({}, @carnet_folder, "shrink_diags")).to eq(false)
  end

  it "la chanson est prioritaire sur le carnet" do
    write_carnet_infos("title: Carnet\nshrink_diags: false\n")
    expect(PageBuilder.resolve_shrink_option({ "shrink_diags" => "true" }, @carnet_folder, "shrink_diags")).to eq(true)
  end

  it "la chanson peut aussi désactiver malgré un carnet à true" do
    write_carnet_infos("title: Carnet\nshrink_diags: true\n")
    expect(PageBuilder.resolve_shrink_option({ "shrink_diags" => "false" }, @carnet_folder, "shrink_diags")).to eq(false)
  end

  it "chaque propriété (shrink_diags/shrink_tabla/shrink_score) se résout indépendamment" do
    write_carnet_infos("title: Carnet\nshrink_tabla: false\n")
    meta = { "shrink_score" => "false" }
    expect(PageBuilder.resolve_shrink_option(meta, @carnet_folder, "shrink_diags")).to eq(true)
    expect(PageBuilder.resolve_shrink_option(meta, @carnet_folder, "shrink_tabla")).to eq(false)
    expect(PageBuilder.resolve_shrink_option(meta, @carnet_folder, "shrink_score")).to eq(false)
  end

  describe "shrink_text (défaut FALSE, inverse des autres)" do
    it "false par défaut, absent de la chanson et du carnet" do
      write_carnet_infos("title: Carnet\n")
      expect(PageBuilder.resolve_shrink_option({}, @carnet_folder, "shrink_text", default: false)).to eq(false)
    end

    it "le carnet peut l'activer explicitement" do
      write_carnet_infos("title: Carnet\nshrink_text: true\n")
      expect(PageBuilder.resolve_shrink_option({}, @carnet_folder, "shrink_text", default: false)).to eq(true)
    end

    it "la chanson reste prioritaire sur le carnet, comme les autres" do
      write_carnet_infos("title: Carnet\nshrink_text: true\n")
      meta = { "shrink_text" => "false" }
      expect(PageBuilder.resolve_shrink_option(meta, @carnet_folder, "shrink_text", default: false)).to eq(false)
    end
  end
end
