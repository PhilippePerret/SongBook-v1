# frozen_string_literal: true

require_relative "../spec_helper"
require "layout"
require "tmpdir"

# `shrink_diags` (diags : rétrécissement SOUS DIAG_W, SVG compris — voir en-tête
# `Layout` et `diag_column_width`).
RSpec.describe "rétrécissement des diagrammes (shrink_diags)" do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def svg_paths(count, side: 60)
    (1..count).map do |i|
      path = File.join(@dir, "diag-#{i}.svg")
      File.write(path, %(<svg viewBox="0 0 #{side} #{side}"></svg>))
      path
    end
  end

  after { Layout.shrink_diags = true }

  it "situation normale (les diags tiennent déjà à DIAG_W) : jamais rétréci, option ou pas" do
    paths = svg_paths(6)
    [true, false].each do |flag|
      Layout.shrink_diags = flag
      expect(Layout.diag_column_width(paths, 500, 500)).to eq(Layout::DIAG_W)
    end
  end

  it "situation critique (ne tiennent pas à DIAG_W), shrink_diags: true => rétrécit sous DIAG_W" do
    paths = svg_paths(6)
    Layout.shrink_diags = true
    w = Layout.diag_column_width(paths, 300, 300)
    expect(w).to be < Layout::DIAG_W
    expect(w).to be >= Layout::MIN_SIZE[:diags][:width]
  end

  it "situation critique (ne tiennent pas à DIAG_W), shrink_diags: false => reste à DIAG_W (déborde sur la page suivante)" do
    paths = svg_paths(6)
    Layout.shrink_diags = false
    expect(Layout.diag_column_width(paths, 300, 300)).to eq(Layout::DIAG_W)
  end
end

# `shrink_tabla`/`shrink_score` : pas de taille nominale propre, donc pertinents
# SEULEMENT pour une image à taille fixe (PNG/JPEG) — jamais pour un SVG.
RSpec.describe "rétrécissement tabla/score (shrink_tabla/shrink_score)" do
  after do
    Layout.shrink_tabla = true
    Layout.shrink_score = true
  end

  it "raster_image? reconnaît PNG/JPEG (toute casse), pas SVG" do
    expect(Layout.raster_image?("x.png")).to eq(true)
    expect(Layout.raster_image?("x.PNG")).to eq(true)
    expect(Layout.raster_image?("x.jpg")).to eq(true)
    expect(Layout.raster_image?("x.jpeg")).to eq(true)
    expect(Layout.raster_image?("x.svg")).to eq(false)
  end

  it "SVG : jamais rétrécissable, quelle que soit la valeur de l'option (n'a pas de sens)" do
    Layout.shrink_tabla = true
    expect(Layout.tabla_shrinkable?("partition.svg")).to eq(false)
    Layout.shrink_score = true
    expect(Layout.score_shrinkable?("partition.svg")).to eq(false)
  end

  it "PNG/JPEG : rétrécissable seulement si l'option correspondante est active" do
    Layout.shrink_tabla = true
    expect(Layout.tabla_shrinkable?("tabla.png")).to eq(true)
    Layout.shrink_tabla = false
    expect(Layout.tabla_shrinkable?("tabla.png")).to eq(false)

    Layout.shrink_score = true
    expect(Layout.score_shrinkable?("score.jpg")).to eq(true)
    Layout.shrink_score = false
    expect(Layout.score_shrinkable?("score.jpg")).to eq(false)
  end

  it "shrink_tabla n'affecte pas shrink_score, et inversement (options indépendantes)" do
    Layout.shrink_tabla = false
    Layout.shrink_score = true
    expect(Layout.tabla_shrinkable?("t.png")).to eq(false)
    expect(Layout.score_shrinkable?("s.png")).to eq(true)
  end
end
