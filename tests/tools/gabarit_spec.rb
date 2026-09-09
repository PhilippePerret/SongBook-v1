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
    items = parse("{tabs: intro.tab; shrink: true;}")
    expect(items.first.type).to eq(:tabs)
    expect(items.first.data[:tabs]).to eq("intro.tab")
  end

  it "'tab' est un diminutif toléré pour 'tabs' " do
    items = parse("{tab: intro+couplet;}")
    expect(items.first.type).to eq(:tabs)
    expect(items.first.data[:tabs]).to eq("intro+couplet")
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

  # "Au fur et à mesure" : un "+" ne laisse AUCUNE gouttière entre les sous-blocs
  # concaténés (contrairement à une row normale, `col1_w`/`col2_w`/`h_gutter`) —
  # `top_margin:` comble ce manque, espace FIXE ajouté juste au-dessus du sous-bloc
  # portant la directive (`Line#top_gap`, consommé par `Layout.block_visual_height`/
  # `Layout.draw_block`).
  describe "top_margin: sur un sous-bloc \"+\"-concaténé (Line#top_gap)" do
    def lyr_blocks_for(*names_with_lines)
      names_with_lines.to_h { |name, lines| [name, Block.new(lines: lines.map { |t| Line.new(segments: [Segment.new(chord: nil, text: t)]) }, directives: {}, paired_with_previous: false)] }
    end

    it "posé sur le 2e sous-bloc : top_gap SEULEMENT sur sa 1re ligne, en pt" do
      lyr_blocks = lyr_blocks_for(["a", ["ligne a1", "ligne a2"]], ["b", ["ligne b1", "ligne b2"]])
      row_directives = { "b" => { top_margin: "10pt" } }

      block = PageBuilder.resolve_block(lyr_blocks, "a+b", [], Hash.new(0), row_directives: row_directives)

      expect(block.lines.map(&:top_gap)).to eq([nil, nil, 10.0, nil])
    end

    it "unité différente (cm) : convertie en pt (`AppConfig.length_pt`)" do
      lyr_blocks = lyr_blocks_for(["a", ["x"]], ["b", ["y"]])
      row_directives = { "b" => { top_margin: "1cm" } }

      block = PageBuilder.resolve_block(lyr_blocks, "a+b", [], Hash.new(0), row_directives: row_directives)

      expect(block.lines.last.top_gap).to be_within(0.01).of(28.35)
    end

    it "Layout.block_visual_height/draw_block : la hauteur du bloc augmente EXACTEMENT du top_gap" do
      lyr_blocks = lyr_blocks_for(["a", ["x"]], ["b", ["y"]])
      with_margin = PageBuilder.resolve_block(lyr_blocks, "a+b", [], Hash.new(0), row_directives: { "b" => { top_margin: "10pt" } })
      without_margin = PageBuilder.resolve_block(lyr_blocks, "a+b", [], Hash.new(0), row_directives: {})

      pdf = Prawn::Document.new
      chord_ascent = Layout.font_metric(pdf, Layout.scaled_chord_size) { pdf.font.ascender }
      text_ascent = Layout.font_metric(pdf, Options.get(:font_size)) { pdf.font.ascender }
      text_descent = Layout.font_metric(pdf, Options.get(:font_size)) { pdf.font.descender }
      height_with = Layout.block_visual_height(pdf, chord_ascent, text_ascent, text_descent, with_margin, nil)
      height_without = Layout.block_visual_height(pdf, chord_ascent, text_ascent, text_descent, without_margin, nil)

      expect(height_with - height_without).to be_within(0.001).of(10.0)
    end

    it "posé sur le 1er sous-bloc (tout en haut du bloc final) : stocké sur sa 1re ligne, mais SANS EFFET (Layout.block_visual_height ignore le top_gap de la ligne 0, rien à ajouter au-dessus)" do
      lyr_blocks = lyr_blocks_for(["a", ["x"]], ["b", ["y"]])
      with_margin = PageBuilder.resolve_block(lyr_blocks, "a+b", [], Hash.new(0), row_directives: { "a" => { top_margin: "10pt" } })
      without_margin = PageBuilder.resolve_block(lyr_blocks, "a+b", [], Hash.new(0), row_directives: {})

      expect(with_margin.lines.first.top_gap).to eq(10.0)

      pdf = Prawn::Document.new
      chord_ascent = Layout.font_metric(pdf, Layout.scaled_chord_size) { pdf.font.ascender }
      text_ascent = Layout.font_metric(pdf, Options.get(:font_size)) { pdf.font.ascender }
      text_descent = Layout.font_metric(pdf, Options.get(:font_size)) { pdf.font.descender }
      height_with = Layout.block_visual_height(pdf, chord_ascent, text_ascent, text_descent, with_margin, nil)
      height_without = Layout.block_visual_height(pdf, chord_ascent, text_ascent, text_descent, without_margin, nil)
      expect(height_with).to eq(height_without)
    end
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
