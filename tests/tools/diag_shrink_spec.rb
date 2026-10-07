# frozen_string_literal: true

require_relative "../spec_helper"
require "layout"
require "tmpdir"

# `diags_shrink` (diags : rétrécissement SOUS DIAG_W, SVG compris — voir en-tête
# `Layout` et `diag_column_width`).
RSpec.describe "rétrécissement des diagrammes (diags_shrink)" do
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

  after do
    Options.set!(:diags_shrink, true)
    Options.set!(:diags_size, Layout::DIAG_W.to_f)
  end

  it "situation normale (les diags tiennent déjà à DIAG_W) : jamais rétréci, option ou pas" do
    paths = svg_paths(6)
    [true, false].each do |flag|
      Options.set!(:diags_shrink, flag)
      expect(Layout.diag_column_width(paths, 500, 500)).to eq(Layout::DIAG_W)
    end
  end

  # RAD3 : plancher = `DIAG_W` (taille normale) — voir `diag_row_spec.rb`.
  it "situation critique (ne tiennent pas à DIAG_W), diags_shrink: true => jamais sous DIAG_W (plancher)" do
    paths = svg_paths(6)
    Options.set!(:diags_shrink, true)
    expect(Layout.diag_column_width(paths, 300, 300)).to eq(Layout::DIAG_W)
  end

  it "situation critique, diags_shrink: true, diags_size > DIAG_W => rétrécit, jamais sous le plancher" do
    paths = svg_paths(6)
    Options.set!(:diags_shrink, true)
    Options.set!(:diags_size, 90.0)
    w = Layout.diag_column_width(paths, 450, 450)
    expect(w).to be < 90
    expect(w).to be >= Layout::MIN_SIZE[:diags][:width]
  end

  it "situation critique (ne tiennent pas à DIAG_W), diags_shrink: false => reste à DIAG_W (déborde sur la page suivante)" do
    paths = svg_paths(6)
    Options.set!(:diags_shrink, false)
    expect(Layout.diag_column_width(paths, 300, 300)).to eq(Layout::DIAG_W)
  end
end

# `tabs_shrink`/`scores_shrink` : pas de taille nominale propre, donc pertinents
# SEULEMENT pour une image à taille fixe (PNG/JPEG) — jamais pour un SVG.
RSpec.describe "rétrécissement tabs/score (tabs_shrink/scores_shrink)" do
  after do
    Options.set!(:tabs_shrink, true)
    Options.set!(:scores_shrink, true)
  end

  it "raster_image? reconnaît PNG/JPEG (toute casse), pas SVG" do
    expect(Layout.raster_image?("x.png")).to eq(true)
    expect(Layout.raster_image?("x.PNG")).to eq(true)
    expect(Layout.raster_image?("x.jpg")).to eq(true)
    expect(Layout.raster_image?("x.jpeg")).to eq(true)
    expect(Layout.raster_image?("x.svg")).to eq(false)
  end

  it "SVG : jamais rétrécissable, quelle que soit la valeur de l'option (n'a pas de sens)" do
    Options.set!(:tabs_shrink, true)
    expect(Layout.tabs_shrinkable?("partition.svg")).to eq(false)
    Options.set!(:scores_shrink, true)
    expect(Layout.score_shrinkable?("partition.svg")).to eq(false)
  end

  it "PNG/JPEG : rétrécissable seulement si l'option correspondante est active" do
    Options.set!(:tabs_shrink, true)
    expect(Layout.tabs_shrinkable?("tabs.png")).to eq(true)
    Options.set!(:tabs_shrink, false)
    expect(Layout.tabs_shrinkable?("tabs.png")).to eq(false)

    Options.set!(:scores_shrink, true)
    expect(Layout.score_shrinkable?("score.jpg")).to eq(true)
    Options.set!(:scores_shrink, false)
    expect(Layout.score_shrinkable?("score.jpg")).to eq(false)
  end

  it "tabs_shrink n'affecte pas scores_shrink, et inversement (options indépendantes)" do
    Options.set!(:tabs_shrink, false)
    Options.set!(:scores_shrink, true)
    expect(Layout.tabs_shrinkable?("t.png")).to eq(false)
    expect(Layout.score_shrinkable?("s.png")).to eq(true)
  end
end
