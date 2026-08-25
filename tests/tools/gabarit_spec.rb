# frozen_string_literal: true

require_relative "../spec_helper"
require "page_builder"
require "layout"
require "dsl_parser"
require "tmpdir"

# Tests des outils
RSpec.describe "lecture du gabarit (.gab)" do
  around do |example|
    Dir.mktmpdir do |dir|
      Layout.building_log_path = File.join(dir, "building.log")
      File.write(Layout.building_log_path, "")
      example.run
    end
  end

  def parse(content)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "c.gab")
      File.write(path, content)
      PageBuilder.parse_gab(path)
    end
  end

  it "Lire une indication sur le titre" do
    items = parse("{title: band;}")
    expect(items.first.type).to eq(:title)
  end

  it "Lire une indication sur une tablature" do
    items = parse("{tabla: intro.tab; shrink: true;}")
    expect(items.first.type).to eq(:tabla)
    expect(items.first.data[:tabla]).to eq("intro.tab")
  end

  it "Placer un couplet précis à cet endroit" do
    items = parse("{song: mon-couplet}")
    expect(items.first.data[:names]).to eq(["mon-couplet"])
  end

  it "Placer un bloc de paroles nommé directement" do
    items = parse("{couplet-1}")
    expect(items.first.data[:names]).to eq(["couplet-1"])
  end

  it "Coller deux blocs de paroles en un seul (+)" do
    items = parse("{couplet-1} + {couplet-2}")
    expect(items.first.data[:names]).to eq(["couplet-1+couplet-2"])
  end

  it "Ne pas perdre un bloc qui a ses propres réglages en plus d'être collé à un autre" do
    items = parse("{intro; align:Right;} + {couplet-1}")
    expect(items.first.type).to eq(:row)
    expect(items.first.data[:directives]["intro"]).to eq({ align: "Right" })
  end

  it "Mettre deux blocs côte à côte (//)" do
    items = parse("{couplet-1} // {couplet-2}")
    expect(items.first.data[:names]).to eq(["couplet-1", "couplet-2"])
  end

  it "Reconnaître qu'un couplet et sa suite sont du même genre de bloc" do
    expect(PageBuilder.block_kind("couplet-3")).to eq("couplet")
  end

  describe "ranger les blocs de paroles tout seul (sans .gab)" do
    let(:blocks) do
      {
        "couplet-1" => Block.new(lines: [Line.new(segments: [])], directives: {}),
        "couplet-2" => Block.new(lines: [Line.new(segments: [])], directives: {}),
        "refrain-1" => Block.new(lines: [Line.new(segments: [])], directives: {}),
        "vide-1" => Block.new(lines: [], directives: {}),
      }
    end
    let(:order) { %w[couplet-1 couplet-2 refrain-1 vide-1] }

    it "Mettre côte à côte deux blocs du même genre" do
      items = PageBuilder.default_items(blocks, order)
      rows = items.select { |i| i.type == :row }
      expect(rows.first.data[:names]).to eq(%w[couplet-1 couplet-2])
    end

    it "Mettre chaque bloc sur sa propre ligne si demandé" do
      items = PageBuilder.default_items(blocks, order, lyrics_flux: :vertical)
      rows = items.select { |i| i.type == :row }
      expect(rows.map { |r| r.data[:names] }).to eq([["couplet-1"], ["couplet-2"], ["refrain-1"]])
    end

    it "Ne pas gaspiller une place pour un bloc complètement vide" do
      items = PageBuilder.default_items(blocks, order)
      rows = items.select { |i| i.type == :row }
      all_names = rows.flat_map { |r| r.data[:names] }
      expect(all_names).not_to include("vide-1")
    end

    it "Refuser poliment un réglage pas encore prêt (lyrics_flux libre)" do
      expect { PageBuilder.default_items(blocks, order, lyrics_flux: :free) }.to raise_error(RuntimeError, /pas encore implémenté/)
    end
  end
end
